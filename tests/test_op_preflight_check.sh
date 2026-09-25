#!/usr/bin/env bash
# tests/test_op_preflight_check.sh
#
# Unit tests for the --check / --status mode added in #282.
#
# Strategy: PATH-shim `op` with a stub that aborts on call. The
# --check path is contractually forbidden to invoke op (no biometric
# possible). If any test triggers op, the stub exits 99 and the test
# fails with a clear diagnostic.
#
# The cache file is synthesized directly into a scratch
# OP_PREFLIGHT_CACHE_DIR so tests don't depend on prior preflight runs.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/op-preflight.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/op-preflight-check-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# The script's compiled-in DEFAULT_TTL_SECONDS (#765: 4h -> 10h). Fixtures
# that must read as fresh or stale with NO OP_PREFLIGHT_TTL_SECONDS in the
# environment are anchored on this value, so a future default bump moves
# them together instead of silently flipping test_check_stale_cache.
SCRIPT_DEFAULT_TTL_SECONDS=36000

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a PATH-shim `op` stub that aborts on any call. Used in all
# --check tests to enforce the "never invoke op" contract.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/op" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: --check invoked op with args: $*" >&2
exit 99
EOF
chmod +x "$STUB_DIR/op"

# Also stub `ssh` to detect SSH-warm attempts. --check must NEVER warm
# SSH (would also potentially burn biometric on the 1Password SSH agent).
cat > "$STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: --check invoked ssh with args: $*" >&2
exit 98
EOF
chmod +x "$STUB_DIR/ssh"

# Stub `gh` to prove --check never mutates the active account. A
# config read is harmless; any auth switch is the #411 regression.
cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "config get")
    echo "nathanpayne-cursor"
    exit 0
    ;;
  "auth switch")
    echo "FATAL: --check invoked gh auth switch with args: $*" >&2
    exit 97
    ;;
  *)
    echo "FATAL: --check invoked unexpected gh command: $*" >&2
    exit 96
    ;;
esac
EOF
chmod +x "$STUB_DIR/gh"

# Helper: synthesize a cache file whose embedded CREATED_AT epoch is
# <age_seconds> in the past. Freshness is compared against that epoch and
# the TTL the SCRIPT resolves (OP_PREFLIGHT_TTL_SECONDS in the environment,
# else its own default) — the OP_PREFLIGHT_TTL_SECONDS line written into
# the file is inert for that comparison, so fixtures elsewhere in this file
# that still carry a 14400 line are unaffected by the #765 default bump.
# Resolve the op:// reference the SCRIPT maps this agent to, by reading the
# script rather than restating its table here. A fixture that hardcoded the
# item would silently stop matching the moment the map changed -- which is the
# exact failure this field exists to catch, so the fixture must not be able to
# reproduce it.
source_ref_for_agent() {
  local agent="$1" item
  item=$(sed -n "s/^[[:space:]]*${agent})[[:space:]]*echo \"\([a-z0-9]\{26\}\)\".*/\1/p" "$SCRIPT" | head -1)
  if [ -z "$item" ]; then
    echo "FIXTURE ERROR: cannot derive the 1Password item for agent '$agent' from $SCRIPT" >&2
    echo "(reviewer_pat_item_for's shape changed; update source_ref_for_agent)" >&2
    exit 1
  fi
  printf 'op://Private/%s/token' "$item"
}

make_aged_cache() {
  local dir="$1" agent="$2" age_seconds="$3" reviewer_pat="$4" author_pat="$5"
  local source_ref="${6:-$(source_ref_for_agent "$agent")}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local epoch
  epoch=$(( $(date +%s) - age_seconds ))
  cat > "$dir/op-preflight-$agent.env" <<EOF
# synthetic test cache
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=$SCRIPT_DEFAULT_TTL_SECONDS
OP_PREFLIGHT_AGENT=$agent
OP_PREFLIGHT_MODE=review
OP_PREFLIGHT_DONE=1
OP_PREFLIGHT_REVIEWER_PAT=$reviewer_pat
OP_PREFLIGHT_AUTHOR_PAT=$author_pat
OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF=$source_ref
EOF
  chmod 600 "$dir/op-preflight-$agent.env"
}

# A cached token is opaque: it records the VALUE, not which 1Password item it
# came from. So remapping an agent to a different item leaves every warm cache
# happily serving a token minted from the OLD item until the TTL expires.
# Measured on 2026-08-21: item o6ekjxjjl5gq6rmcneomrjahpu was repurposed from
# codex to the nathanpayne-robot CI account, and warm codex caches kept
# emitting a robot token after the map was corrected. Service-account token
# mode already compared the source ref; the interactive path did not.
test_check_rejects_cache_from_a_different_pat_item() {
  local case_dir="$WORKDIR/case-srcref"
  local out rc

  # 1. Correct source ref -> cache is honoured.
  make_fresh_cache "$case_dir" claude "rev-srcref-ok" "auth-srcref-ok"
  rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "source-ref: a cache from the CURRENT item should be honoured; rc=$rc out=$out"
    return
  fi

  # 2. Ref naming a DIFFERENT item -> refuse, so a remap takes effect at once
  #    instead of after the TTL.
  make_fresh_cache "$case_dir" claude "rev-srcref-old" "auth-srcref-old" \
    "op://Private/o6ekjxjjl5gq6rmcneomrjahpu/token"
  rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "source-ref: a cache minted from a DIFFERENT item was accepted; the remap would not take effect until the TTL expired"
    return
  fi

  # 3. Field absent (a cache written before the field existed) -> also refuse.
  #    Trusting an unattributable token is the same bug with less evidence.
  make_fresh_cache "$case_dir" claude "rev-srcref-none" "auth-srcref-none"
  grep -v '^OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF=' \
    "$case_dir/op-preflight-claude.env" > "$case_dir/tmp.env"
  mv "$case_dir/tmp.env" "$case_dir/op-preflight-claude.env"
  chmod 600 "$case_dir/op-preflight-claude.env"
  rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "source-ref: a pre-change cache carrying no source ref was accepted"
    return
  fi

  pass "a cached reviewer PAT is refused unless it names the item the agent currently maps to"
}

# Helper: move the deploy fields a fixture wrote into the (pre-slot) session
# file into the slot for <context project>. Since #1318 a pre-slot SA entry is
# never exported (it names the shared, cross-project key file), so fixtures
# that exercise the SA project/usability validation put it in a slot, the path
# that validation now guards.
session_deploy_fields_to_slot() { # <cache_dir> <slot context project>
  local main="$1/op-preflight-claude.env" ctx="$2" fields epoch
  fields='^(GOOGLE_APPLICATION_CREDENTIALS|OP_PREFLIGHT_ADC_TMPFILE|OP_PREFLIGHT_FIREBASE_SA_TMPFILE|OP_PREFLIGHT_FIREBASE_PROJECT|CF_API_TOKEN)='
  epoch=$(sed -n 's/^OP_PREFLIGHT_CREATED_AT_EPOCH=//p' "$main")
  {
    printf 'OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=%s\n' "$epoch"
    printf 'OP_PREFLIGHT_DEPLOY_CONTEXT=%s\n' "$ctx"
    grep -E "$fields" "$main"
  } > "$1/op-preflight-claude-deploy-fb-$ctx.slot"
  grep -Ev "$fields" "$main" > "$main.tmp" || true
  mv "$main.tmp" "$main"
  chmod 600 "$main" "$1/op-preflight-claude-deploy-fb-$ctx.slot"
}

# Helper: synthesize a fresh cache file.
make_fresh_cache() {
  local dir="$1" agent="$2" reviewer_pat="$3" author_pat="$4"
  make_aged_cache "$dir" "$agent" 0 "$reviewer_pat" "$author_pat" "${5:-}"
}

# Helper: synthesize a STALE cache file — one hour older than the script's
# default TTL, so it reads as stale without an OP_PREFLIGHT_TTL_SECONDS
# override.
make_stale_cache() {
  local dir="$1" agent="$2"
  make_aged_cache "$dir" "$agent" \
    $(( SCRIPT_DEFAULT_TTL_SECONDS + 3600 )) stale-rev stale-auth
}

# ---------------------------------------------------------------------------
# Test 1: --check --print-exports with a fresh cache emits exports, never
# invokes op. Before #1021 this was bare `--check`; the exports moved behind
# the explicit flag, so this test now pins the EXPORT path and
# test_check_emits_no_credentials pins the liveness path.
# ---------------------------------------------------------------------------
test_check_fresh_cache() {
  local case_dir="$WORKDIR/case1"
  make_fresh_cache "$case_dir" claude "rev-pat-1" "author-pat-1"

  local out err rc
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check --print-exports 2>"$WORKDIR/case1.err") || rc=$?
  rc=${rc:-0}
  err=$(cat "$WORKDIR/case1.err")

  if [ "$rc" -ne 0 ]; then
    fail "test_check_fresh_cache: expected rc=0, got rc=$rc; stderr=$err"
    return
  fi
  if ! echo "$out" | grep -q "OP_PREFLIGHT_REVIEWER_PAT=rev-pat-1"; then
    fail "test_check_fresh_cache: stdout missing reviewer PAT export; got $out"
    return
  fi
  if ! echo "$out" | grep -q "OP_PREFLIGHT_AUTHOR_PAT=author-pat-1"; then
    fail "test_check_fresh_cache: stdout missing author PAT export; got $out"
    return
  fi
  if echo "$err" | grep -q FATAL; then
    fail "test_check_fresh_cache: --check invoked op or ssh; stderr=$err"
    return
  fi
  pass "test_check_fresh_cache: --print-exports emits exports without op/ssh/gh auth switch"
}

# ---------------------------------------------------------------------------
# Test 2: --check with no cache exits non-zero, never invokes op.
# ---------------------------------------------------------------------------
test_check_missing_cache() {
  local case_dir="$WORKDIR/case2"  # never created
  local err rc=0
  PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check 2>"$WORKDIR/case2.err" >"$WORKDIR/case2.out" || rc=$?
  err=$(cat "$WORKDIR/case2.err")
  if [ "$rc" -eq 0 ]; then
    fail "test_check_missing_cache: expected non-zero exit, got 0"
    return
  fi
  # Pre-#1021 this asserted literal emptiness. The property it protects is "no
  # credentials when there is no valid cache"; stdout now also carries the
  # temporary compat guard, which is inert text. Assert the property, and that
  # what IS there is the guard, so anything else appearing here still trips.
  if grep -qE '(OP_PREFLIGHT_REVIEWER_PAT|OP_PREFLIGHT_AUTHOR_PAT)=' "$WORKDIR/case2.out"; then
    fail "test_check_missing_cache: stdout carries a PAT export on the miss path: $(cat "$WORKDIR/case2.out")"
    return
  fi
  if [ -s "$WORKDIR/case2.out" ] && ! grep -qF 'return 1 2>/dev/null || exit 1' "$WORKDIR/case2.out"; then
    fail "test_check_missing_cache: stdout on miss is not an eval-failing guard, got $(cat "$WORKDIR/case2.out")"
    return
  fi
  if ! echo "$err" | grep -q "cache missing or stale"; then
    fail "test_check_missing_cache: stderr missing remediation; got $err"
    return
  fi
  if echo "$err" | grep -q FATAL; then
    fail "test_check_missing_cache: --check invoked op or ssh; stderr=$err"
    return
  fi
  pass "test_check_missing_cache: missing cache exits non-zero with remediation"
}

# ---------------------------------------------------------------------------
# Test 3: --check with a STALE cache exits non-zero, never invokes op.
# ---------------------------------------------------------------------------
test_check_stale_cache() {
  local case_dir="$WORKDIR/case3"
  make_stale_cache "$case_dir" claude

  local err rc=0
  PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check 2>"$WORKDIR/case3.err" >"$WORKDIR/case3.out" || rc=$?
  err=$(cat "$WORKDIR/case3.err")
  if [ "$rc" -eq 0 ]; then
    fail "test_check_stale_cache: expected non-zero exit, got 0"
    return
  fi
  if ! echo "$err" | grep -q "cache missing or stale"; then
    fail "test_check_stale_cache: stderr missing remediation; got $err"
    return
  fi
  if echo "$err" | grep -q FATAL; then
    fail "test_check_stale_cache: --check invoked op or ssh; stderr=$err"
    return
  fi
  pass "test_check_stale_cache: stale cache exits non-zero with remediation"
}

# ---------------------------------------------------------------------------
# Test 4: --check refuses to combine with --refresh / --purge / --purge-all.
# ---------------------------------------------------------------------------
test_check_mutex() {
  for flag in --refresh --purge --purge-all; do
    local rc=0
    PATH="$STUB_DIR:$PATH" "$SCRIPT" --agent claude --check "$flag" \
      >"$WORKDIR/mutex.out" 2>"$WORKDIR/mutex.err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "test_check_mutex: expected non-zero exit for --check $flag, got 0"
      return
    fi
    if ! grep -q "mutually exclusive" "$WORKDIR/mutex.err"; then
      fail "test_check_mutex: --check $flag missing mutex error; stderr=$(cat "$WORKDIR/mutex.err")"
      return
    fi
  done
  pass "test_check_mutex: --check rejects --refresh / --purge / --purge-all"
}

# ---------------------------------------------------------------------------
# Test 5: --status is an alias for --check.
# ---------------------------------------------------------------------------
test_status_alias() {
  local case_dir="$WORKDIR/case5"
  make_fresh_cache "$case_dir" claude "rev-pat-5" "author-pat-5"

  local out rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --status 2>"$WORKDIR/case5.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_status_alias: expected rc=0, got rc=$rc"
    return
  fi
  # The alias must track the CURRENT default, not the pre-#1021 one: bare
  # --status is a liveness check and must not leak either PAT.
  if echo "$out" | grep -q "rev-pat-5\|author-pat-5"; then
    fail "test_status_alias: bare --status leaked a PAT on stdout"
    return
  fi
  local out_exp rc_exp=0
  out_exp=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --status --print-exports 2>/dev/null) || rc_exp=$?
  if [ "$rc_exp" -ne 0 ] || ! echo "$out_exp" | grep -q "OP_PREFLIGHT_REVIEWER_PAT=rev-pat-5"; then
    fail "test_status_alias: --status --print-exports did not emit the reviewer PAT"
    return
  fi
  pass "test_status_alias: --status behaves like --check on both sides of the split"
}

# ---------------------------------------------------------------------------
# #1021: the liveness check and the token dump were the same command, so an
# agent testing whether the cache was warm wrote both live PATs into its
# transcript. Bare --check must now write NO credential material to stdout or
# stderr on ANY exit path. Driven with sentinel PATs so the assertion is on the
# values themselves rather than on an `export ` prefix a refactor could rename.
# ---------------------------------------------------------------------------
test_check_emits_no_credentials() {
  local sentinel_rev="SENTINEL-REVIEWER-b3f9c1" sentinel_auth="SENTINEL-AUTHOR-7d2e04"
  local fresh="$WORKDIR/case1021_fresh" stale="$WORKDIR/case1021_stale"
  local missing="$WORKDIR/case1021_missing"   # deliberately never created
  local incomplete="$WORKDIR/case1021_incomplete"
  make_fresh_cache "$fresh" claude "$sentinel_rev" "$sentinel_auth"
  make_aged_cache "$stale" claude \
    $(( SCRIPT_DEFAULT_TTL_SECONDS + 3600 )) "$sentinel_rev" "$sentinel_auth"
  # A review-mode cache queried under --mode deploy is the "present but
  # incomplete" exit path, which is a third place stdout could carry material.
  make_fresh_cache "$incomplete" claude "$sentinel_rev" "$sentinel_auth"

  local label dir extra_args
  for spec in "fresh:$fresh:" "stale:$stale:" "missing:$missing:" "incomplete:$incomplete:--mode deploy"; do
    label="${spec%%:*}"
    dir="$(printf '%s' "$spec" | cut -d: -f2)"
    extra_args="$(printf '%s' "$spec" | cut -d: -f3)"
    # shellcheck disable=SC2086
    PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$dir" \
      "$SCRIPT" --agent claude --check $extra_args \
      >"$WORKDIR/nc-$label.out" 2>"$WORKDIR/nc-$label.err" || true
    if grep -qF "$sentinel_rev" "$WORKDIR/nc-$label.out" "$WORKDIR/nc-$label.err" \
       || grep -qF "$sentinel_auth" "$WORKDIR/nc-$label.out" "$WORKDIR/nc-$label.err"; then
      fail "test_check_emits_no_credentials: bare --check leaked a PAT on the $label path"
      return
    fi
  done
  pass "test_check_emits_no_credentials: no PAT on stdout or stderr across fresh/stale/missing/incomplete"
}

# ---------------------------------------------------------------------------
# #1021, the migration hazard. Bare --check used to populate OP_PREFLIGHT_*_PAT
# through `eval "$(...)"`. Simply printing nothing would leave an un-migrated
# caller with both variables UNSET -- and an empty GH_TOKEN does not fail:
# `GH_TOKEN="" gh api user` exits 0 and attributes to whatever account the gh
# keyring has active, which is a wrong byline nobody sees. So stdout carries a
# guard that fails loudly when evaluated. This is temporary; when it is removed,
# this test goes with it.
# ---------------------------------------------------------------------------
test_check_compat_guard_fails_closed() {
  local case_dir="$WORKDIR/case1021_guard"
  make_fresh_cache "$case_dir" claude "guard-rev" "guard-auth"

  local rc=0
  bash -c '
    set -e
    eval "$(PATH="$2:$PATH" OP_PREFLIGHT_CACHE_DIR="$3" "$1" --agent claude --check 2>/dev/null)"
    echo REACHED
  ' _ "$SCRIPT" "$STUB_DIR" "$case_dir" >"$WORKDIR/guard.out" 2>"$WORKDIR/guard.err" || rc=$?

  if [ "$rc" -eq 0 ]; then
    fail "test_check_compat_guard_fails_closed: un-migrated eval succeeded (rc=0); it must fail closed"
    return
  fi
  if grep -q REACHED "$WORKDIR/guard.out"; then
    fail "test_check_compat_guard_fails_closed: execution continued past the eval"
    return
  fi
  if ! grep -q -- "--print-exports" "$WORKDIR/guard.err"; then
    fail "test_check_compat_guard_fails_closed: stderr does not name the remediation; got $(cat "$WORKDIR/guard.err")"
    return
  fi
  # The miss path needs the guard too, and for a reason worth stating: it was
  # ALREADY silently-empty before #1021, so an un-migrated eval on a stale or
  # missing cache has always left both PATs unset and fallen through to the
  # keyring. Emitting the guard on every --check exit path rather than only the
  # one that used to print keeps the rule single -- and means the eventual
  # removal has one shape, not two.
  local miss_dir="$WORKDIR/case1021_guard_miss"   # never created
  local rc_miss=0
  bash -c '
    set -e
    eval "$(PATH="$2:$PATH" OP_PREFLIGHT_CACHE_DIR="$3" "$1" --agent claude --check 2>/dev/null)"
    echo REACHED
  ' _ "$SCRIPT" "$STUB_DIR" "$miss_dir" >"$WORKDIR/guard-miss.out" 2>/dev/null || rc_miss=$?
  if [ "$rc_miss" -eq 0 ] || grep -q REACHED "$WORKDIR/guard-miss.out"; then
    fail "test_check_compat_guard_fails_closed: un-migrated eval on a MISSING cache did not fail closed"
    return
  fi
  pass "test_check_compat_guard_fails_closed: un-migrated eval exits non-zero on fresh and missing caches"
}

# ---------------------------------------------------------------------------
# #1021 acceptance: the export path still works for its real consumers --
# asserted through an actual `eval`, not by grepping stdout, because what
# matters is that both variables end up POPULATED in the caller's shell.
# ---------------------------------------------------------------------------
test_print_exports_eval_populates_both_vars() {
  local case_dir="$WORKDIR/case1021_eval"
  make_fresh_cache "$case_dir" claude "eval-rev-pat" "eval-auth-pat"

  local out rc=0
  out=$(bash -c '
    eval "$(PATH="$2:$PATH" OP_PREFLIGHT_CACHE_DIR="$3" "$1" --agent claude --check --print-exports 2>/dev/null)"
    printf "%s|%s
" "${OP_PREFLIGHT_REVIEWER_PAT:-UNSET}" "${OP_PREFLIGHT_AUTHOR_PAT:-UNSET}"
  ' _ "$SCRIPT" "$STUB_DIR" "$case_dir") || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "test_print_exports_eval_populates_both_vars: eval failed rc=$rc"
    return
  fi
  if [ "$out" != "eval-rev-pat|eval-auth-pat" ]; then
    fail "test_print_exports_eval_populates_both_vars: expected both vars populated, got [$out]"
    return
  fi
  pass "test_print_exports_eval_populates_both_vars: eval \"\$(... --print-exports)\" populates both PATs"
}

# ---------------------------------------------------------------------------
# #1021, Codex P1 round 2. The compat guard was gated on --print-exports, so the
# path this change now tells EVERYONE to use was the one path it did not
# protect. `eval "$(cmd)"` discards the command substitution's exit status: a
# script that exits 2 having printed nothing makes `eval` return 0, so the
# documented caller continued with both PATs unset and fell through to the gh
# keyring -- the exact wrong-identity behaviour #1021 closes. The invariant is
# that stdout always carries something that FAILS when evaluated, unless real
# exports are being emitted.
# ---------------------------------------------------------------------------
test_print_exports_error_paths_fail_closed() {
  local stale="$WORKDIR/case1021_pe_stale" missing="$WORKDIR/case1021_pe_missing"
  local incomplete="$WORKDIR/case1021_pe_incomplete"
  make_stale_cache "$stale" claude
  make_fresh_cache "$incomplete" claude "pe-rev" "pe-auth"   # review cache, asked for deploy

  local label dir extra want rc out
  for spec in "stale:$stale::--mode review" "missing:$missing::--mode review" \
              "incomplete:$incomplete:--mode deploy:--mode deploy"; do
    label="${spec%%:*}"
    dir="$(printf '%s' "$spec" | cut -d: -f2)"
    extra="$(printf '%s' "$spec" | cut -d: -f3)"
    want="$(printf '%s' "$spec" | cut -d: -f4)"
    rc=0
    out=$(bash -c '
      eval "$(PATH="$2:$PATH" OP_PREFLIGHT_CACHE_DIR="$3" "$1" --agent claude --check --print-exports $4 2>/dev/null)"
      printf "REACHED:%s:%s" "${OP_PREFLIGHT_REVIEWER_PAT:-UNSET}" "${OP_PREFLIGHT_AUTHOR_PAT:-UNSET}"
    ' _ "$SCRIPT" "$STUB_DIR" "$dir" "$extra" 2>"$WORKDIR/pe-$label.err") || rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "test_print_exports_error_paths_fail_closed: $label path returned rc=0; eval swallowed the failure (out=$out)"
      return
    fi
    if [ -n "$out" ]; then
      fail "test_print_exports_error_paths_fail_closed: execution continued past the eval on the $label path ($out)"
      return
    fi
    # review and deploy share the per-agent session file but not its contents, so
    # a review cache is exactly what makes the deploy case incomplete. The
    # remediation has to name the mode the caller ASKED for or it sends them
    # back to the run that already failed them.
    if ! grep -q -- "$want" "$WORKDIR/pe-$label.err"; then
      fail "test_print_exports_error_paths_fail_closed: $label path should name '$want'; got $(cat "$WORKDIR/pe-$label.err")"
      return
    fi
  done
  pass "test_print_exports_error_paths_fail_closed: --print-exports fails closed on stale/missing/incomplete"
}

# ---------------------------------------------------------------------------
# #1021, CodeRabbit round 2. The guard line is EVALUATED by the caller, so every
# value interpolated into it is code. $MODE is not validated on the --check
# path, and before the fix `--mode 'review"; <command>; echo "'` escaped the
# double-quoted echo and ran in the caller's shell. Reproduced against the real
# script before fixing.
# ---------------------------------------------------------------------------
test_check_guard_is_injection_safe() {
  local case_dir="$WORKDIR/case1021_inj"   # never created -> the failure guard path
  local canary="$WORKDIR/INJECTION-CANARY"
  rm -f "$canary"

  local rc=0
  bash -c '
    eval "$(PATH="$2:$PATH" OP_PREFLIGHT_CACHE_DIR="$3" "$1" --agent claude --check --print-exports \
      --mode "review\"; touch $4; echo \"" 2>/dev/null)"
    echo REACHED
  ' _ "$SCRIPT" "$STUB_DIR" "$case_dir" "$canary" >"$WORKDIR/inj.out" 2>/dev/null || rc=$?

  if [ -e "$canary" ]; then
    fail "test_check_guard_is_injection_safe: evaluating the guard executed --mode content"
    rm -f "$canary"
    return
  fi
  # Still fail closed: quoting must not turn the guard into a no-op.
  if [ "$rc" -eq 0 ] || grep -q REACHED "$WORKDIR/inj.out"; then
    fail "test_check_guard_is_injection_safe: guard stopped failing closed once quoted (rc=$rc)"
    return
  fi
  pass "test_check_guard_is_injection_safe: hostile --mode is inert text and the guard still fails closed"
}

# ---------------------------------------------------------------------------
# Test 6: OP_PREFLIGHT_QUIET=1 collapses the cache-hit stderr block.
# ---------------------------------------------------------------------------
test_quiet_mode() {
  local case_dir="$WORKDIR/case6"
  make_fresh_cache "$case_dir" claude "rev-pat-6" "author-pat-6"

  local err rc=0
  PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    OP_PREFLIGHT_QUIET=1 \
    "$SCRIPT" --agent claude --check >"$WORKDIR/case6.out" 2>"$WORKDIR/case6.err" || rc=$?
  err=$(cat "$WORKDIR/case6.err")
  if [ "$rc" -ne 0 ]; then
    fail "test_quiet_mode: expected rc=0, got rc=$rc; stderr=$err"
    return
  fi
  if ! echo "$err" | grep -q "no biometric burned"; then
    fail "test_quiet_mode: stderr missing single-line confirmation; got $err"
    return
  fi
  if echo "$err" | grep -q "── Preflight cached hit"; then
    fail "test_quiet_mode: stderr still contains verbose block; got $err"
    return
  fi
  pass "test_quiet_mode: OP_PREFLIGHT_QUIET=1 collapses verbose block"
}

# ---------------------------------------------------------------------------
# Test 7: Default --mode is review (not all). Without --mode, dry-run
# should report Reviewer + Author PAT reads but NOT GCP ADC.
# ---------------------------------------------------------------------------
test_default_mode_is_review() {
  local err rc=0
  PATH="$STUB_DIR:$PATH" \
    "$SCRIPT" --agent claude --dry-run >"$WORKDIR/case7.out" 2>"$WORKDIR/case7.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_default_mode_is_review: dry-run rc=$rc"
    return
  fi
  err=$(cat "$WORKDIR/case7.err")
  if ! echo "$err" | grep -q "mode review"; then
    fail "test_default_mode_is_review: dry-run header missing 'mode review'; got $err"
    return
  fi
  if echo "$err" | grep -q "Would read: GCP ADC"; then
    fail "test_default_mode_is_review: default mode should NOT load GCP ADC; got $err"
    return
  fi
  pass "test_default_mode_is_review: default --mode is review (no ADC)"
}

# ---------------------------------------------------------------------------
# Test 8 (#765): the compiled-in default TTL is 10h. A cache created 5h ago
# — stale under the previous 4h default — is a HIT with no
# OP_PREFLIGHT_TTL_SECONDS in the environment, and the cache-hit line
# reports the 36000s window.
# ---------------------------------------------------------------------------
test_default_ttl_is_ten_hours() {
  local case_dir="$WORKDIR/case8"
  make_aged_cache "$case_dir" claude 18000 "rev-pat-8" "author-pat-8"

  local out err rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check --print-exports 2>"$WORKDIR/case8.err") || rc=$?
  err=$(cat "$WORKDIR/case8.err")

  if [ "$rc" -ne 0 ]; then
    fail "test_default_ttl_is_ten_hours: 5h-old cache should be fresh under the 10h default; rc=$rc stderr=$err"
    return
  fi
  if ! echo "$out" | grep -q "OP_PREFLIGHT_REVIEWER_PAT=rev-pat-8"; then
    fail "test_default_ttl_is_ten_hours: stdout missing reviewer PAT export; got $out"
    return
  fi
  if ! echo "$err" | grep -q "TTL 36000s"; then
    fail "test_default_ttl_is_ten_hours: stderr should report the 36000s default TTL; got $err"
    return
  fi
  pass "test_default_ttl_is_ten_hours: default TTL is 36000s (10h)"
}

# ---------------------------------------------------------------------------
# Test 9 (#765): OP_PREFLIGHT_TTL_SECONDS still overrides the default in
# BOTH directions — shortening it expires an otherwise-fresh cache, and
# lengthening it revives a cache older than the default.
# ---------------------------------------------------------------------------
test_ttl_override_both_directions() {
  # Shorten: a 5h-old cache is fresh by default, stale under a 60s TTL.
  local short_dir="$WORKDIR/case9-short"
  make_aged_cache "$short_dir" claude 18000 "rev-pat-9a" "author-pat-9a"

  local err rc=0
  PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$short_dir" \
    OP_PREFLIGHT_TTL_SECONDS=60 \
    "$SCRIPT" --agent claude --check --print-exports >"$WORKDIR/case9a.out" 2>"$WORKDIR/case9a.err" || rc=$?
  err=$(cat "$WORKDIR/case9a.err")
  if [ "$rc" -eq 0 ]; then
    fail "test_ttl_override_both_directions: OP_PREFLIGHT_TTL_SECONDS=60 should expire a 5h-old cache, got rc=0"
    return
  fi
  if ! echo "$err" | grep -q "cache missing or stale"; then
    fail "test_ttl_override_both_directions: shortened TTL missing remediation; got $err"
    return
  fi

  # Lengthen: an 11h-old cache is stale by default, fresh under a 24h TTL.
  local long_dir="$WORKDIR/case9-long"
  make_aged_cache "$long_dir" claude 39600 "rev-pat-9b" "author-pat-9b"

  local out
  rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$long_dir" \
    OP_PREFLIGHT_TTL_SECONDS=86400 \
    "$SCRIPT" --agent claude --check --print-exports 2>"$WORKDIR/case9b.err") || rc=$?
  err=$(cat "$WORKDIR/case9b.err")
  if [ "$rc" -ne 0 ]; then
    fail "test_ttl_override_both_directions: OP_PREFLIGHT_TTL_SECONDS=86400 should revive an 11h-old cache; rc=$rc stderr=$err"
    return
  fi
  if ! echo "$out" | grep -q "OP_PREFLIGHT_REVIEWER_PAT=rev-pat-9b"; then
    fail "test_ttl_override_both_directions: lengthened TTL missing reviewer PAT export; got $out"
    return
  fi
  if ! echo "$err" | grep -q "TTL 86400s"; then
    fail "test_ttl_override_both_directions: stderr should report the overridden TTL; got $err"
    return
  fi
  pass "test_ttl_override_both_directions: OP_PREFLIGHT_TTL_SECONDS shortens and lengthens the window"
}

# ---------------------------------------------------------------------------
# test_check_deploy_no_python3_probe (nathanpayne-codex Phase 4b r1 on
# PR #292): --check --print-exports --mode deploy must NOT invoke python3 to validate
# ADC. Probe by PATH-shimming python3 with an aborting stub and
# verifying the --check --print-exports path exits 0 with cached exports rather than
# aborting via the stub.
# ---------------------------------------------------------------------------
test_check_deploy_no_python3_probe() {
  local cache_dir="$WORKDIR/deploy-no-python3-cache"
  mkdir -p "$cache_dir" && chmod 700 "$cache_dir"
  # This fixture models the shared ADC context, not a Firebase project. Run
  # from an empty directory and discard a caller-provided project override so
  # consumer repositories with a root .firebaserc cannot change the fixture's
  # intended cache context.
  local context_dir="$WORKDIR/deploy-no-python3-context"
  mkdir -p "$context_dir"
  local adc_file="$WORKDIR/deploy-no-python3-adc.json"
  # Fake but well-formed service_account JSON. adc_is_usable
  # short-circuits to OK on service_account creds without HTTP, but
  # if --check --print-exports honors the contract it shouldn't even reach
  # adc_is_usable.
  cat > "$adc_file" <<'JSON'
{"type":"service_account","project_id":"x","private_key_id":"x","private_key":"x","client_email":"x"}
JSON
  local epoch
  epoch=$(date +%s)
  cat > "$cache_dir/op-preflight-claude.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=claude
OP_PREFLIGHT_MODE=all
OP_PREFLIGHT_DONE=1
OP_PREFLIGHT_REVIEWER_PAT=stub-reviewer
OP_PREFLIGHT_AUTHOR_PAT=stub-author
GOOGLE_APPLICATION_CREDENTIALS=$adc_file
OP_PREFLIGHT_ADC_TMPFILE=$adc_file
EOF
  chmod 600 "$cache_dir/op-preflight-claude.env"

  # Aborting python3 stub.
  local py_stub="$WORKDIR/stub-bin-py"
  mkdir -p "$py_stub"
  cat > "$py_stub/python3" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: --check --print-exports --mode deploy invoked python3 with args: $*" >&2
exit 97
EOF
  chmod +x "$py_stub/python3"

  local out rc=0
  out=$(cd "$context_dir" && \
        env -u OP_PREFLIGHT_FIREBASE_PROJECT_ID \
          OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
          PATH="$py_stub:$STUB_DIR:$PATH" \
          "$SCRIPT" --agent claude --mode deploy --check --print-exports 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_check_deploy_no_python3_probe: --check --print-exports --mode deploy returned rc=$rc; out=$out"
    return
  fi
  if echo "$out" | grep -q "invoked python3"; then
    fail "test_check_deploy_no_python3_probe: --check --print-exports --mode deploy invoked python3 (ADC probe leaked)"
    return
  fi
  if ! echo "$out" | grep -q "export GOOGLE_APPLICATION_CREDENTIALS="; then
    fail "test_check_deploy_no_python3_probe: --check --print-exports --mode deploy did not emit ADC export; out=$out"
    return
  fi
  pass "test_check_deploy_no_python3_probe: --check --print-exports --mode deploy emits ADC without python3 probe"
}

# ---------------------------------------------------------------------------
# test_check_deploy_firebase_sa_no_python3_probe: --check --print-exports must stay a
# no-probe path even when the cached deploy credential is a Firebase SA
# marker and the checkout has a .firebaserc.
# ---------------------------------------------------------------------------
test_check_deploy_firebase_sa_no_python3_probe() {
  local case_dir="$WORKDIR/deploy-firebase-no-python3"
  local cache_dir="$case_dir/cache"
  local py_stub="$case_dir/stub-bin-py"
  local project="merge-path-test"
  local sa_file="$case_dir/firebase-sa.json"
  mkdir -p "$case_dir" "$cache_dir" "$py_stub"

  cat > "$case_dir/.firebaserc" <<JSON
{
  "projects": { "default": "$project" },
  "hosting": { "default": "wrong-project" }
}
JSON
  cat > "$sa_file" <<JSON
{
  "type": "service_account",
  "project_id": "$project",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@${project}.iam.gserviceaccount.com",
  "client_id": "0"
}
JSON

  local epoch
  epoch=$(date +%s)
  cat > "$cache_dir/op-preflight-claude.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=claude
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$project
EOF
  chmod 600 "$cache_dir/op-preflight-claude.env"
  session_deploy_fields_to_slot "$cache_dir" "$project"

  cat > "$py_stub/python3" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: --check --print-exports --mode deploy invoked python3 with args: $*" >&2
exit 97
EOF
  chmod +x "$py_stub/python3"

  local out rc=0
  (
    cd "$case_dir"
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      PATH="$py_stub:$STUB_DIR:$PATH" \
      "$SCRIPT" --agent claude --mode deploy --check --print-exports 2>&1
  ) >"$case_dir/out" || rc=$?
  out="$(cat "$case_dir/out")"

  if [ "$rc" -ne 0 ]; then
    fail "test_check_deploy_firebase_sa_no_python3_probe: --check --print-exports returned rc=$rc; out=$out"
    return
  fi
  if echo "$out" | grep -q "invoked python3"; then
    fail "test_check_deploy_firebase_sa_no_python3_probe: --check --print-exports invoked python3; out=$out"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_SA_TMPFILE="; then
    fail "test_check_deploy_firebase_sa_no_python3_probe: missing Firebase SA marker export; out=$out"
    return
  fi
  pass "test_check_deploy_firebase_sa_no_python3_probe: --check --print-exports emits Firebase SA without python3 probe"
}

# ---------------------------------------------------------------------------
# test_check_deploy_firebase_sa_project_mismatch_fails_closed:
# --check --print-exports is probe-free, but it must still refuse a Firebase SA cache
# whose project marker/file no longer match the checkout.
# ---------------------------------------------------------------------------
test_check_deploy_firebase_sa_project_mismatch_fails_closed() {
  local case_dir="$WORKDIR/deploy-firebase-check-mismatch"
  local cache_dir="$case_dir/cache"
  local py_stub="$case_dir/stub-bin-py"
  local cached_project="project-a"
  local current_project="project-b"
  local sa_file="$case_dir/firebase-sa.json"
  mkdir -p "$case_dir" "$cache_dir" "$py_stub"

  cat > "$case_dir/.firebaserc" <<JSON
{ "projects": { "default": "$current_project" } }
JSON
  cat > "$sa_file" <<JSON
{
  "type": "service_account",
  "project_id": "$cached_project",
  "client_email": "firebase-deployer@${cached_project}.iam.gserviceaccount.com"
}
JSON

  local epoch
  epoch=$(date +%s)
  cat > "$cache_dir/op-preflight-claude.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=claude
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$cached_project
EOF
  chmod 600 "$cache_dir/op-preflight-claude.env"
  session_deploy_fields_to_slot "$cache_dir" "$current_project"

  cat > "$py_stub/python3" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: --check --mode deploy invoked python3 with args: $*" >&2
exit 97
EOF
  chmod +x "$py_stub/python3"

  local out rc=0
  (
    cd "$case_dir"
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      PATH="$py_stub:$STUB_DIR:$PATH" \
      "$SCRIPT" --agent claude --mode deploy --check 2>&1
  ) >"$case_dir/out" || rc=$?
  out="$(cat "$case_dir/out")"

  if [ "$rc" -eq 0 ]; then
    fail "test_check_deploy_firebase_sa_project_mismatch_fails_closed: --check should fail closed; out=$out"
    return
  fi
  if echo "$out" | grep -q "invoked python3"; then
    fail "test_check_deploy_firebase_sa_project_mismatch_fails_closed: --check invoked python3; out=$out"
    return
  fi
  if ! echo "$out" | grep -q "cached Firebase project SA key is for '$cached_project', but current project is '$current_project'"; then
    fail "test_check_deploy_firebase_sa_project_mismatch_fails_closed: missing mismatch warning; out=$out"
    return
  fi
  pass "test_check_deploy_firebase_sa_project_mismatch_fails_closed: --check fails closed on project drift"
}

# ---------------------------------------------------------------------------
# test_deploy_mode_prefers_firebase_sa_over_gcp_adc (#154/#211): in a
# Firebase repo, --mode deploy should cache the project Firebase-vault
# SA key first and must not probe the stale shared GCP ADC item when
# that key is available.
# ---------------------------------------------------------------------------
test_deploy_mode_prefers_firebase_sa_over_gcp_adc() {
  local case_dir="$WORKDIR/firebase-sa-preflight"
  local cache_dir="$case_dir/cache"
  local bin_dir="$case_dir/bin"
  local project="merge-path-test"
  local shared_adc_uri="op://Private/test-shared-adc/credential"
  local op_log="$case_dir/op.log"
  mkdir -p "$case_dir" "$cache_dir" "$bin_dir"

  cat > "$case_dir/.firebaserc" <<JSON
{ "projects": { "default": "$project" } }
JSON

  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$op_log"
case "\${1:-}" in
  document)
    shift
    if [ "\${1:-}" != "get" ]; then
      exit 1
    fi
    shift
    out_path=""
    while [ \$# -gt 0 ]; do
      if [ "\${1:-}" = "--out-file" ]; then
        shift
        out_path="\${1:-}"
      fi
      shift || true
    done
    if [ -z "\$out_path" ]; then
      exit 1
    fi
    cat > "\$out_path" <<'JSON'
{
  "type": "service_account",
  "project_id": "merge-path-test",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@merge-path-test.iam.gserviceaccount.com",
  "client_id": "0",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
JSON
    exit 0
    ;;
  read)
    if [ "\${2:-}" = "$shared_adc_uri" ]; then
      echo "FATAL: deploy preflight read stale shared GCP ADC despite Firebase SA key" >&2
      exit 88
    fi
    # Cloudflare token is optional; return empty/unavailable.
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  local out err rc=0
  (
    cd "$case_dir"
    PATH="$bin_dir:$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="$shared_adc_uri" \
      "$SCRIPT" --agent claude --mode deploy >"$case_dir/out" 2>"$case_dir/err"
  ) || rc=$?
  out="$(cat "$case_dir/out")"
  err="$(cat "$case_dir/err")"

  if [ "$rc" -ne 0 ]; then
    fail "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: rc=$rc; stderr=$err"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_SA_TMPFILE="; then
    fail "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: missing Firebase SA marker export; out=$out"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_PROJECT=$project"; then
    fail "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: missing Firebase project export; out=$out"
    return
  fi
  if echo "$out" | grep -q "export OP_PREFLIGHT_ADC_TMPFILE"; then
    fail "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: should not export shared ADC marker; out=$out"
    return
  fi
  if grep -qF "$shared_adc_uri" "$op_log"; then
    fail "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: op read touched shared GCP ADC; log=$(cat "$op_log")"
    return
  fi
  if ! echo "$err" | grep -q "Firebase SA key ($project): loaded"; then
    fail "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: summary missing Firebase SA loaded line; stderr=$err"
    return
  fi
  pass "test_deploy_mode_prefers_firebase_sa_over_gcp_adc: Firebase SA cached before shared ADC"
}

# ---------------------------------------------------------------------------
# test_deploy_mode_refreshes_unusable_cached_firebase_sa (#154/#211):
# a stale/corrupt preflight-cached Firebase SA file must force the
# outer fast path into the real refresh flow, not return a cache hit
# with deploy credentials silently unset.
# ---------------------------------------------------------------------------
test_deploy_mode_refreshes_unusable_cached_firebase_sa() {
  local case_dir="$WORKDIR/firebase-sa-refresh"
  local cache_dir="$case_dir/cache"
  local bin_dir="$case_dir/bin"
  local project="merge-path-test"
  local shared_adc_uri="op://Private/test-shared-adc-refresh/credential"
  local op_log="$case_dir/op.log"
  local bad_sa_file="$case_dir/bad-preflight-sa.json"
  mkdir -p "$case_dir" "$cache_dir" "$bin_dir"

  cat > "$case_dir/.firebaserc" <<JSON
{ "projects": { "default": "$project" } }
JSON
  printf '{not-json\n' > "$bad_sa_file"

  local epoch
  epoch=$(date +%s)
  cat > "$cache_dir/op-preflight-claude.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=claude
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$bad_sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$bad_sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$project
EOF
  chmod 600 "$cache_dir/op-preflight-claude.env"
  session_deploy_fields_to_slot "$cache_dir" "$project"

  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$op_log"
case "\${1:-}" in
  document)
    shift
    if [ "\${1:-}" != "get" ]; then
      exit 1
    fi
    shift
    out_path=""
    while [ \$# -gt 0 ]; do
      if [ "\${1:-}" = "--out-file" ]; then
        shift
        out_path="\${1:-}"
      fi
      shift || true
    done
    if [ -z "\$out_path" ]; then
      exit 1
    fi
    cat > "\$out_path" <<'JSON'
{
  "type": "service_account",
  "project_id": "merge-path-test",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@merge-path-test.iam.gserviceaccount.com",
  "client_id": "0",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
JSON
    exit 0
    ;;
  read)
    if [ "\${2:-}" = "$shared_adc_uri" ]; then
      echo "FATAL: refresh should re-read Firebase SA before shared GCP ADC" >&2
      exit 88
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  local out err rc=0
  (
    cd "$case_dir"
    PATH="$bin_dir:$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="$shared_adc_uri" \
      "$SCRIPT" --agent claude --mode deploy >"$case_dir/out" 2>"$case_dir/err"
  ) || rc=$?
  out="$(cat "$case_dir/out")"
  err="$(cat "$case_dir/err")"

  if [ "$rc" -ne 0 ]; then
    fail "test_deploy_mode_refreshes_unusable_cached_firebase_sa: rc=$rc; stderr=$err"
    return
  fi
  if ! echo "$err" | grep -q "refreshing deploy credentials"; then
    fail "test_deploy_mode_refreshes_unusable_cached_firebase_sa: missing refresh warning; stderr=$err"
    return
  fi
  if ! grep -q "document get" "$op_log"; then
    fail "test_deploy_mode_refreshes_unusable_cached_firebase_sa: refresh did not re-read Firebase SA; log=$(cat "$op_log")"
    return
  fi
  if grep -qF "$shared_adc_uri" "$op_log"; then
    fail "test_deploy_mode_refreshes_unusable_cached_firebase_sa: refresh touched shared GCP ADC; log=$(cat "$op_log")"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_SA_TMPFILE="; then
    fail "test_deploy_mode_refreshes_unusable_cached_firebase_sa: missing refreshed Firebase SA marker export; out=$out"
    return
  fi
  pass "test_deploy_mode_refreshes_unusable_cached_firebase_sa: unusable cached SA forces refresh"
}

# ---------------------------------------------------------------------------
# test_deploy_mode_refreshes_mismatched_cached_firebase_sa (#154/#211):
# a project-A Firebase SA cache must not be re-exported in project B
# within the preflight TTL.
# ---------------------------------------------------------------------------
test_deploy_mode_refreshes_mismatched_cached_firebase_sa() {
  local case_dir="$WORKDIR/firebase-sa-project-mismatch"
  local cache_dir="$case_dir/cache"
  local bin_dir="$case_dir/bin"
  local cached_project="project-a"
  local current_project="project-b"
  local shared_adc_uri="op://Private/test-shared-adc-mismatch/credential"
  local op_log="$case_dir/op.log"
  local cached_sa_file="$case_dir/project-a-sa.json"
  mkdir -p "$case_dir" "$cache_dir" "$bin_dir"

  cat > "$case_dir/.firebaserc" <<JSON
{ "projects": { "default": "$current_project" } }
JSON
  cat > "$cached_sa_file" <<JSON
{
  "type": "service_account",
  "project_id": "$cached_project",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@${cached_project}.iam.gserviceaccount.com",
  "client_id": "0",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
JSON

  local epoch
  epoch=$(date +%s)
  cat > "$cache_dir/op-preflight-claude.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=claude
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$cached_sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$cached_sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$cached_project
EOF
  chmod 600 "$cache_dir/op-preflight-claude.env"
  session_deploy_fields_to_slot "$cache_dir" "$current_project"

  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$op_log"
case "\${1:-}" in
  document)
    shift
    if [ "\${1:-}" != "get" ]; then
      exit 1
    fi
    shift
    out_path=""
    while [ \$# -gt 0 ]; do
      if [ "\${1:-}" = "--out-file" ]; then
        shift
        out_path="\${1:-}"
      fi
      shift || true
    done
    if [ -z "\$out_path" ]; then
      exit 1
    fi
    cat > "\$out_path" <<'JSON'
{
  "type": "service_account",
  "project_id": "project-b",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@project-b.iam.gserviceaccount.com",
  "client_id": "0",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
JSON
    exit 0
    ;;
  read)
    if [ "\${2:-}" = "$shared_adc_uri" ]; then
      echo "FATAL: project mismatch should re-read current Firebase SA before shared GCP ADC" >&2
      exit 88
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  local out err rc=0
  (
    cd "$case_dir"
    PATH="$bin_dir:$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="$shared_adc_uri" \
      "$SCRIPT" --agent claude --mode deploy >"$case_dir/out" 2>"$case_dir/err"
  ) || rc=$?
  out="$(cat "$case_dir/out")"
  err="$(cat "$case_dir/err")"

  if [ "$rc" -ne 0 ]; then
    fail "test_deploy_mode_refreshes_mismatched_cached_firebase_sa: rc=$rc; stderr=$err"
    return
  fi
  if ! echo "$err" | grep -q "cached Firebase project SA key is for '$cached_project', but current project is '$current_project'"; then
    fail "test_deploy_mode_refreshes_mismatched_cached_firebase_sa: missing project mismatch warning; stderr=$err"
    return
  fi
  if ! grep -q "document get" "$op_log"; then
    fail "test_deploy_mode_refreshes_mismatched_cached_firebase_sa: refresh did not re-read current Firebase SA; log=$(cat "$op_log")"
    return
  fi
  if grep -qF "$shared_adc_uri" "$op_log"; then
    fail "test_deploy_mode_refreshes_mismatched_cached_firebase_sa: refresh touched shared GCP ADC; log=$(cat "$op_log")"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_PROJECT=$current_project"; then
    fail "test_deploy_mode_refreshes_mismatched_cached_firebase_sa: missing refreshed current-project export; out=$out"
    return
  fi
  pass "test_deploy_mode_refreshes_mismatched_cached_firebase_sa: project mismatch forces refresh"
}

# ---------------------------------------------------------------------------
# test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch (#154/#211):
# the session marker may still name the current project even if the
# deterministic Firebase SA tempfile was overwritten. The fast path must
# validate the file itself before re-exporting it.
# ---------------------------------------------------------------------------
test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch() {
  local case_dir="$WORKDIR/firebase-sa-file-mismatch"
  local cache_dir="$case_dir/cache"
  local bin_dir="$case_dir/bin"
  local current_project="project-b"
  local wrong_project="project-a"
  local shared_adc_uri="op://Private/test-shared-adc-file-mismatch/credential"
  local op_log="$case_dir/op.log"
  mkdir -p "$case_dir" "$cache_dir" "$bin_dir"
  local cached_sa_file="$cache_dir/op-preflight-claude-firebase-sa.json"

  cat > "$case_dir/.firebaserc" <<JSON
{ "projects": { "default": "$current_project" } }
JSON
  cat > "$cached_sa_file" <<JSON
{
  "type": "service_account",
  "project_id": "$wrong_project",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@${wrong_project}.iam.gserviceaccount.com",
  "client_id": "0",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
JSON

  local epoch
  epoch=$(date +%s)
  cat > "$cache_dir/op-preflight-claude.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=claude
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$cached_sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$cached_sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$current_project
EOF
  chmod 600 "$cache_dir/op-preflight-claude.env"
  session_deploy_fields_to_slot "$cache_dir" "$current_project"

  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$op_log"
case "\${1:-}" in
  document)
    shift
    if [ "\${1:-}" != "get" ]; then
      exit 1
    fi
    shift
    out_path=""
    while [ \$# -gt 0 ]; do
      if [ "\${1:-}" = "--out-file" ]; then
        shift
        out_path="\${1:-}"
      fi
      shift || true
    done
    if [ -z "\$out_path" ]; then
      exit 1
    fi
    if [ -s "\$out_path" ]; then
      echo "FATAL: op document get destination was not truncated before fetch" >&2
      exit 77
    fi
    cat > "\$out_path" <<'JSON'
{
  "type": "service_account",
  "project_id": "project-b",
  "private_key_id": "fake-key-id",
  "private_key": "REDACTED_TEST_FIXTURE_NOT_A_REAL_KEY",
  "client_email": "firebase-deployer@project-b.iam.gserviceaccount.com",
  "client_id": "0",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
JSON
    exit 0
    ;;
  read)
    if [ "\${2:-}" = "$shared_adc_uri" ]; then
      echo "FATAL: file mismatch should re-read current Firebase SA before shared GCP ADC" >&2
      exit 88
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  local out err rc=0
  (
    cd "$case_dir"
    PATH="$bin_dir:$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="$shared_adc_uri" \
      "$SCRIPT" --agent claude --mode deploy >"$case_dir/out" 2>"$case_dir/err"
  ) || rc=$?
  out="$(cat "$case_dir/out")"
  err="$(cat "$case_dir/err")"

  if [ "$rc" -ne 0 ]; then
    fail "test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch: rc=$rc; stderr=$err"
    return
  fi
  if ! echo "$err" | grep -q "cached Firebase project SA key file does not match current project '$current_project'"; then
    fail "test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch: missing file mismatch warning; stderr=$err"
    return
  fi
  if ! grep -q "document get" "$op_log"; then
    fail "test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch: refresh did not re-read current Firebase SA; log=$(cat "$op_log")"
    return
  fi
  if grep -qF "$shared_adc_uri" "$op_log"; then
    fail "test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch: refresh touched shared GCP ADC; log=$(cat "$op_log")"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_PROJECT=$current_project"; then
    fail "test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch: missing refreshed current-project export; out=$out"
    return
  fi
  pass "test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch: file mismatch forces refresh"
}

# #466: a review-mode (default) --check cache hit must NOT re-export deploy
# credentials that a prior --mode deploy / --mode all run left in the
# session file. Mode-scoping the emission closes the cross-mode leak.
test_check_review_mode_omits_deploy_creds() {
  local case_dir="$WORKDIR/case_modescope"
  make_fresh_cache "$case_dir" claude "rev-pat-ms" "author-pat-ms"
  # Append deploy creds, as a prior --mode all run would have.
  cat >> "$case_dir/op-preflight-claude.env" <<EOF
GOOGLE_APPLICATION_CREDENTIALS=/tmp/should-not-leak-adc.json
CF_API_TOKEN=cf-secret-should-not-leak
EOF

  local out rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check --print-exports 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_check_review_mode_omits_deploy_creds: expected rc=0, got rc=$rc"
    return
  fi
  if ! echo "$out" | grep -q "OP_PREFLIGHT_REVIEWER_PAT=rev-pat-ms"; then
    fail "test_check_review_mode_omits_deploy_creds: review PAT missing; out=$out"
    return
  fi
  if echo "$out" | grep -q "export GOOGLE_APPLICATION_CREDENTIALS"; then
    fail "test_check_review_mode_omits_deploy_creds: deploy ADC exported into review-mode output; out=$out"
    return
  fi
  if echo "$out" | grep -q "export CF_API_TOKEN"; then
    fail "test_check_review_mode_omits_deploy_creds: CF_API_TOKEN exported into review-mode output; out=$out"
    return
  fi
  # #466 r2: review mode must ALSO actively unset stale deploy vars that a
  # prior --mode deploy/all eval left in the caller's shell.
  if ! echo "$out" | grep -q "unset .*GOOGLE_APPLICATION_CREDENTIALS"; then
    fail "test_check_review_mode_omits_deploy_creds: review mode did not unset stale deploy vars; out=$out"
    return
  fi
  if ! echo "$out" | grep -q "unset .*CF_API_TOKEN"; then
    fail "test_check_review_mode_omits_deploy_creds: review mode did not unset CF_API_TOKEN; out=$out"
    return
  fi
  pass "test_check_review_mode_omits_deploy_creds: review --check --print-exports omits AND unsets stale deploy creds (#466)"
}

# ---------------------------------------------------------------------------
# test_source_gcp_adc_stale_forces_refresh (#469): the non-Firebase GCP ADC
# stale fast-path must force a full re-fetch (exit 2) — symmetric to the
# Firebase-SA branch, which has a behavioral fixture above
# (test_deploy_mode_refreshes_unusable_cached_firebase_sa). The cached ADC
# tempfile may be stale while the 1Password ADC item is fresh; degrading in
# place would skip that refresh. Structural guard against a revert of the
# exit 2 (a full GCP-ADC deploy fixture would duplicate the Firebase one's
# op-stub plumbing for a one-line mirror change).
# ---------------------------------------------------------------------------
test_source_gcp_adc_stale_forces_refresh() {
  # In the stale-ADC else-branch: a 'cached GCP ADC is unusable' warning
  # must be followed by `exit 2` before the block's closing `fi`.
  if awk '
    /cached GCP ADC is unusable/ { found = 1; next }
    found && /^[[:space:]]*exit 2[[:space:]]*$/ { ok = 1 }
    found && /^[[:space:]]*fi[[:space:]]*$/ { exit (ok ? 0 : 1) }
    END { exit (ok ? 0 : 1) }
  ' "$SCRIPT"; then
    pass "test_source_gcp_adc_stale_forces_refresh: stale GCP ADC forces refresh (exit 2), symmetric to Firebase SA"
  else
    fail "test_source_gcp_adc_stale_forces_refresh: non-Firebase ADC stale path must exit 2 to force a re-fetch (#469)"
  fi
}

# ---------------------------------------------------------------------------
# test_deploy_mode_requires_agent (#534.1): `deploy` must stay in the
# --agent-required gate. Cache paths are unconditionally $AGENT-interpolated,
# so `--mode deploy` with no --agent writes a shared anonymous ("") bucket
# that `--purge --agent <name>` can never reclaim and concurrent sessions
# clobber. This was added in #259, dropped by a bulk sync, and restored in
# #534. Behavioral + structural guards so another drop fails CI.
# ---------------------------------------------------------------------------
test_deploy_mode_requires_agent() {
  # Behavioral: --mode deploy with no --agent must fail before doing any work.
  local rc=0
  PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$WORKDIR/deploy-no-agent" \
    "$SCRIPT" --mode deploy >"$WORKDIR/deploy-no-agent.out" 2>"$WORKDIR/deploy-no-agent.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "test_deploy_mode_requires_agent: --mode deploy without --agent unexpectedly succeeded"
    return
  fi
  if ! grep -q "agent is required" "$WORKDIR/deploy-no-agent.err"; then
    fail "test_deploy_mode_requires_agent: missing 'agent is required' diagnostic; stderr=$(cat "$WORKDIR/deploy-no-agent.err")"
    return
  fi
  # The error message itself must enumerate deploy, and no anonymous cache
  # file may have been written.
  if ! grep -qi "deploy" "$WORKDIR/deploy-no-agent.err"; then
    fail "test_deploy_mode_requires_agent: agent-required error does not mention deploy mode"
    return
  fi
  if [ -e "$WORKDIR/deploy-no-agent/op-preflight-.env" ]; then
    fail "test_deploy_mode_requires_agent: anonymous (empty-agent) cache file was written"
    return
  fi
  # Structural: the gate line that requires --agent (the one testing
  # `-z "$AGENT"`) must also include the `deploy` mode token. Guards against
  # a bulk-sync re-dropping deploy even if a future refactor changes the
  # error string. The gate is the only line carrying both tokens.
  if ! awk '
    /-z "\$AGENT" \]\]/ && /"\$MODE" == "deploy"/ { ok = 1 }
    END { exit (ok ? 0 : 1) }
  ' "$SCRIPT"; then
    fail "test_deploy_mode_requires_agent: 'deploy' missing from the --agent-required gate (#534.1 regression)"
    return
  fi
  pass "test_deploy_mode_requires_agent: --mode deploy requires --agent (gate retains deploy)"
}

# ---------------------------------------------------------------------------
# test_deploy_full_fetch_fails_closed_on_unreadable_adc (#534.2 / #534.3):
# on the full-fetch path, when the GCP ADC read fails (op error) under
# `--mode deploy`, preflight must fail closed (exit non-zero) rather than
# emitting OP_PREFLIGHT_DONE=1 with no GOOGLE_APPLICATION_CREDENTIALS — the
# cache-hit path already exit 2's for this. The could-not-read warning must
# also surface op's stderr reason (#534.3).
# ---------------------------------------------------------------------------
test_deploy_full_fetch_fails_closed_on_unreadable_adc() {
  local case_dir="$WORKDIR/deploy-fail-closed"
  local cache_dir="$case_dir/cache"
  local bin_dir="$case_dir/bin"
  local shared_adc_uri="op://Private/test-unreadable-adc/credential"
  mkdir -p "$case_dir" "$cache_dir" "$bin_dir"
  # No .firebaserc → falls through to the GCP ADC branch (not Firebase SA).

  # op stub: every `op read` fails with a recognizable stderr reason; op
  # inject (Phase 1) is not reached in --mode deploy.
  cat > "$bin_dir/op" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  read)
    echo "[ERROR] could not read secret: vault is locked" >&2
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  local out err rc=0
  (
    cd "$case_dir"
    PATH="$bin_dir:$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="$shared_adc_uri" \
      "$SCRIPT" --agent claude --mode deploy >"$case_dir/out" 2>"$case_dir/err"
  ) || rc=$?
  out="$(cat "$case_dir/out")"
  err="$(cat "$case_dir/err")"

  if [ "$rc" -eq 0 ]; then
    fail "test_deploy_full_fetch_fails_closed_on_unreadable_adc: --mode deploy with unreadable ADC unexpectedly succeeded (rc=0); out=$out"
    return
  fi
  if echo "$out" | grep -q "export GOOGLE_APPLICATION_CREDENTIALS"; then
    fail "test_deploy_full_fetch_fails_closed_on_unreadable_adc: exported GOOGLE_APPLICATION_CREDENTIALS despite unreadable ADC; out=$out"
    return
  fi
  if echo "$out" | grep -q "export OP_PREFLIGHT_DONE=1"; then
    fail "test_deploy_full_fetch_fails_closed_on_unreadable_adc: emitted OP_PREFLIGHT_DONE=1 on a failed deploy; out=$out"
    return
  fi
  # #534.3: the warning must include op's stderr reason.
  if ! echo "$err" | grep -q "could not read GCP ADC"; then
    fail "test_deploy_full_fetch_fails_closed_on_unreadable_adc: missing could-not-read warning; stderr=$err"
    return
  fi
  if ! echo "$err" | grep -q "vault is locked"; then
    fail "test_deploy_full_fetch_fails_closed_on_unreadable_adc: warning did not surface op stderr reason (#534.3); stderr=$err"
    return
  fi
  pass "test_deploy_full_fetch_fails_closed_on_unreadable_adc: deploy fails closed on unreadable ADC and surfaces op stderr"
}

# ---------------------------------------------------------------------------
# test_deploy_full_fetch_fail_closed_structural (#534.2): structural guard
# that BOTH the STALE branch and the could-not-read branch of the full-fetch
# ADC path carry a deploy-scoped `exit 1`, symmetric to
# test_source_gcp_adc_stale_forces_refresh's exit-2 guard. A behavioral test
# covers the could-not-read branch; the STALE branch needs a usable-then-
# rejected ADC + python3 oauth round-trip that is impractical to fixture
# hermetically, so assert its fail-closed structurally.
# ---------------------------------------------------------------------------
test_deploy_full_fetch_fail_closed_structural() {
  # STALE branch: a 'GCP ADC: STALE' SUMMARY line must be followed by a
  # deploy-scoped `exit 1` before the branch's closing `fi`.
  if ! awk '
    /GCP ADC: STALE/ { found = 1; next }
    found && /MODE" == "deploy".*exit 1/ { ok = 1 }
    found && /^[[:space:]]*fi[[:space:]]*$/ { exit (ok ? 0 : 1) }
    END { exit (ok ? 0 : 1) }
  ' "$SCRIPT"; then
    fail "test_deploy_full_fetch_fail_closed_structural: STALE ADC branch missing deploy-scoped exit 1 (#534.2)"
    return
  fi
  # Could-not-read branch: a 'GCP ADC: SKIPPED' SUMMARY line must be followed
  # by a deploy-scoped `exit 1` before the branch's closing `fi`.
  if ! awk '
    /GCP ADC: SKIPPED/ { found = 1; next }
    found && /MODE" == "deploy".*exit 1/ { ok = 1 }
    found && /^[[:space:]]*fi[[:space:]]*$/ { exit (ok ? 0 : 1) }
    END { exit (ok ? 0 : 1) }
  ' "$SCRIPT"; then
    fail "test_deploy_full_fetch_fail_closed_structural: could-not-read ADC branch missing deploy-scoped exit 1 (#534.2)"
    return
  fi
  pass "test_deploy_full_fetch_fail_closed_structural: both full-fetch ADC failure branches fail closed under deploy"
}

# ---------------------------------------------------------------------------
# test_preflight_mode_is_exported (#521): the preflight mode must be exported
# on BOTH the cache-hit path and the full-fetch path so a consumer that evals
# the output (e.g. a deploy wrapper that took the fast path / skipped deploy)
# can read which mode ran.
# ---------------------------------------------------------------------------
test_preflight_mode_is_exported() {
  # Sub-case A: cache-hit path — a fresh review cache must emit `export OP_PREFLIGHT_MODE`.
  local case_dir="$WORKDIR/mode-export-cachehit"
  make_fresh_cache "$case_dir" claude "rev-pat-m" "author-pat-m"
  local out rc=0
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check --print-exports 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_preflight_mode_is_exported: cache-hit --check --print-exports rc=$rc"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_MODE=review"; then
    fail "test_preflight_mode_is_exported: cache-hit path did not export OP_PREFLIGHT_MODE; out=$out"
    return
  fi
  pass "test_preflight_mode_is_exported: OP_PREFLIGHT_MODE exported on cache-hit path (#521)"

  # Sub-case B: cold/full-fetch path — a review run with no cache must still
  # emit `export OP_PREFLIGHT_MODE=review` in its output (#556).
  local ff_dir="$WORKDIR/mode-export-fullfetch"
  local ff_cache="$ff_dir/cache"
  local ff_bin="$ff_dir/bin"
  mkdir -p "$ff_dir" "$ff_cache" "$ff_bin"
  # op stub: handle inject (returns PATs), reject everything else.
  cat > "$ff_bin/op" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  inject)
    printf '%s\n' "REVIEWER_PAT=ff-reviewer-pat"
    printf '%s\n' "AUTHOR_PAT=ff-author-pat"
    ;;
  *)
    echo "unexpected op call: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$ff_bin/op"
  rc=0
  out=$(PATH="$ff_bin:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$ff_cache" \
    "$SCRIPT" --agent claude --mode review --skip-ssh 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_preflight_mode_is_exported: full-fetch --mode review rc=$rc"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_MODE=review"; then
    fail "test_preflight_mode_is_exported: full-fetch path did not export OP_PREFLIGHT_MODE; out=$out"
    return
  fi
  pass "test_preflight_mode_is_exported: OP_PREFLIGHT_MODE exported on full-fetch path (#556)"
}

# ---------------------------------------------------------------------------
# test_all_mode_degraded_deploy_does_not_reprompt: a `--mode all` full fetch
# that cannot load any deploy credential (no .firebaserc, GCP ADC unreadable)
# writes a cache without GOOGLE_APPLICATION_CREDENTIALS. The cache-hit path
# used to treat that as cross-mode-invalidated and re-fetch — a fresh Touch ID
# prompt on EVERY `--mode all` call (39 in ~1h on 2026-09-24, all logged as
# reason=cross-mode-invalidation). The degradation is now recorded and reused
# for a short backoff window, bounded by the contracts pinned below.
# ---------------------------------------------------------------------------
make_degraded_op_stub() { # <bin_dir> <op_log>
  cat > "$1/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >> "$2"
case "\${1:-}" in
  inject)
    printf '%s\n' "REVIEWER_PAT=degraded-reviewer-pat"
    printf '%s\n' "AUTHOR_PAT=degraded-author-pat"
    ;;
  read)
    echo "[ERROR] could not read secret: item not found" >&2
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$1/op"
}

run_all_mode() { # <case_dir> <cache_dir> <bin_dir> <label> [extra env...]
  local case_dir="$1" cache_dir="$2" bin_dir="$3" label="$4"
  shift 4
  local rc=0
  (
    cd "$case_dir"
    env PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="op://Private/test-degraded-adc/credential" "$@" \
      "$SCRIPT" --agent claude --mode all --skip-ssh \
      >"$case_dir/$label.out" 2>"$case_dir/$label.err"
  ) || rc=$?
  return "$rc"
}

count_lines() { # <file> <pattern>
  grep -c "$2" "$1" 2>/dev/null || true
}

test_all_mode_degraded_deploy_does_not_reprompt() {
  local case_dir="$WORKDIR/all-degraded"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin"
  local op_log="$case_dir/op.log" bio_log="$case_dir/cache/biometric-log"
  mkdir -p "$cache_dir" "$bin_dir"
  make_degraded_op_stub "$bin_dir" "$op_log"

  # Run 1: cold cache -> one full fetch, degraded deploy leg.
  if ! run_all_mode "$case_dir" "$cache_dir" "$bin_dir" run1; then
    fail "all-degraded: first --mode all failed; stderr=$(cat "$case_dir/run1.err")"
    return
  fi
  local op_calls_after_run1
  op_calls_after_run1=$(wc -l < "$op_log" | tr -d ' ')

  # Run 2: same context, within the window -> cache hit, ZERO op calls.
  if ! run_all_mode "$case_dir" "$cache_dir" "$bin_dir" run2; then
    fail "all-degraded: second --mode all failed; stderr=$(cat "$case_dir/run2.err")"
    return
  fi
  if [ "$(wc -l < "$op_log" | tr -d ' ')" != "$op_calls_after_run1" ]; then
    fail "all-degraded: second --mode all invoked op again (re-prompt loop); op log: $(tr '\n' ' ' < "$op_log")"
    return
  fi
  if [ "$(count_lines "$op_log" '^inject$')" != "1" ] || [ "$(count_lines "$bio_log" 'mode=all')" != "1" ]; then
    fail "all-degraded: expected exactly one op inject and one biometric-log entry across two runs; op=$(tr '\n' ' ' < "$op_log") bio=$(cat "$bio_log")"
    return
  fi
  if ! grep -q "export OP_PREFLIGHT_REVIEWER_PAT=degraded-reviewer-pat" "$case_dir/run2.out" \
     || ! grep -q "export OP_PREFLIGHT_AUTHOR_PAT=degraded-author-pat" "$case_dir/run2.out"; then
    fail "all-degraded: degraded cache hit did not emit the cached PATs; out=$(cat "$case_dir/run2.out")"
    return
  fi
  if grep -q "export GOOGLE_APPLICATION_CREDENTIALS" "$case_dir/run2.out"; then
    fail "all-degraded: degraded cache hit exported GOOGLE_APPLICATION_CREDENTIALS; out=$(cat "$case_dir/run2.out")"
    return
  fi
  # ...clears one an earlier preflight eval left in the caller's shell (its
  # marker proves preflight owns it), but preserves a human override (no
  # marker), which DEPLOYMENT.md ranks first.
  local leaked kept
  leaked=$(GOOGLE_APPLICATION_CREDENTIALS=/tmp/other-project-key.json \
    OP_PREFLIGHT_FIREBASE_SA_TMPFILE=/tmp/other-project-key.json bash -c \
    'eval "$(grep -v "^export OP_PREFLIGHT_.*_PAT=" "$1")"; printf %s "${GOOGLE_APPLICATION_CREDENTIALS:-}"' _ "$case_dir/run2.out")
  if [ -n "$leaked" ]; then
    fail "all-degraded: degraded cache hit left a preflight-owned GOOGLE_APPLICATION_CREDENTIALS ($leaked) in the caller's shell"
    return
  fi
  # shellcheck disable=SC2016  # expanded by the child bash, by design
  kept=$(env -u OP_PREFLIGHT_ADC_TMPFILE -u OP_PREFLIGHT_FIREBASE_SA_TMPFILE \
    GOOGLE_APPLICATION_CREDENTIALS=/tmp/human-override.json bash -c \
    'eval "$(grep -v "^export OP_PREFLIGHT_.*_PAT=" "$1")"; printf %s "${GOOGLE_APPLICATION_CREDENTIALS:-}"' _ "$case_dir/run2.out")
  if [ "$kept" != "/tmp/human-override.json" ]; then
    fail "all-degraded: degraded cache hit erased a human-override GOOGLE_APPLICATION_CREDENTIALS (got '$kept')"
    return
  fi
  # Propagation skew: a pre-slot consumer's NEWER session write that carries
  # only CF_API_TOKEN (its SA/ADC failed) must not be discarded by the older
  # degraded slot -- the next deploy's cache purge depends on it.
  local sess="$cache_dir/op-preflight-claude.env" cf_out
  grep -v '^CF_API_TOKEN=' "$sess" > "$sess.tmp"; mv "$sess.tmp" "$sess"
  sed "s/^OP_PREFLIGHT_CREATED_AT_EPOCH=.*/OP_PREFLIGHT_CREATED_AT_EPOCH=$(date +%s)/" "$sess" > "$sess.tmp"; mv "$sess.tmp" "$sess"
  printf 'CF_API_TOKEN=pre-slot-cf-token\n' >> "$sess"
  sed "s/^OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=.*/OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=$(( $(date +%s) - 5 ))/" \
    "$cache_dir/op-preflight-claude-deploy-adc.slot" > "$cache_dir/slot.tmp" && mv "$cache_dir/slot.tmp" "$cache_dir/op-preflight-claude-deploy-adc.slot"
  cf_out=$(cd "$case_dir" && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode all --skip-ssh 2>/dev/null || true)
  if ! printf '%s\n' "$cf_out" | grep -q '^export CF_API_TOKEN=pre-slot-cf-token$'; then
    fail "all-degraded: a newer pre-slot CF_API_TOKEN was discarded by an older degraded slot"
    return
  fi
  # An ambient CF_API_TOKEN (no ownership marker exists for it) survives a
  # deploy/all run whose optional Cloudflare read failed.
  # shellcheck disable=SC2016  # expanded by the child bash, by design
  kept=$(CF_API_TOKEN=ambient-cf-token bash -c \
    'eval "$(grep -v "^export OP_PREFLIGHT_.*_PAT=" "$1")"; printf %s "${CF_API_TOKEN:-}"' _ "$case_dir/run2.out")
  if [ "$kept" != "ambient-cf-token" ]; then
    fail "all-degraded: a deploy/all hit erased an ambient CF_API_TOKEN (got '$kept')"
    return
  fi
  if ! grep -q "deploy credentials unavailable" "$case_dir/run2.err"; then
    fail "all-degraded: degraded cache hit did not warn that deploy creds are missing; stderr=$(cat "$case_dir/run2.err")"
    return
  fi
  if ! grep -q '^OP_PREFLIGHT_DEPLOY_DEGRADED=1$' "$cache_dir/op-preflight-claude-deploy-adc.slot"; then
    fail "all-degraded: run 1 did not record the deploy degradation in the adc deploy slot"
    return
  fi
  pass "test_all_mode_degraded_deploy_does_not_reprompt: second --mode all with ADC unavailable makes no op call"

  # --check --mode all reuses the degraded verdict too (and never runs op).
  local rc=0
  (cd "$case_dir" && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode all --check >/dev/null 2>"$case_dir/check.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "all-degraded: --check --mode all rejected a degraded cache within the window; stderr=$(cat "$case_dir/check.err")"
    return
  fi
  pass "test_all_mode_degraded_deploy_does_not_reprompt: --check --mode all accepts the degraded cache"

  # --mode deploy must never accept the degraded verdict: it re-fetches and
  # fails closed (#534.2) rather than succeeding without a credential.
  rc=0
  (cd "$case_dir" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    GCP_ADC_OP_URI="op://Private/test-degraded-adc/credential" \
    "$SCRIPT" --agent claude --mode deploy >"$case_dir/deploy.out" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] || grep -q "OP_PREFLIGHT_DONE=1" "$case_dir/deploy.out"; then
    fail "all-degraded: --mode deploy accepted a degraded --mode all cache (rc=$rc)"
    return
  fi
  pass "test_all_mode_degraded_deploy_does_not_reprompt: --mode deploy still fails closed on a degraded cache"

  # A different Firebase-project context was never evaluated -> re-fetch.
  local injects_before
  injects_before=$(count_lines "$op_log" '^inject$')
  if ! run_all_mode "$case_dir" "$cache_dir" "$bin_dir" run3 OP_PREFLIGHT_FIREBASE_PROJECT_ID=other-project; then
    fail "all-degraded: --mode all in a new Firebase context failed; stderr=$(cat "$case_dir/run3.err")"
    return
  fi
  if [ "$(count_lines "$op_log" '^inject$')" != "$((injects_before + 1))" ]; then
    fail "all-degraded: a degraded verdict for the adc context was reused for project 'other-project'"
    return
  fi
  pass "test_all_mode_degraded_deploy_does_not_reprompt: a new Firebase-project context re-fetches"

  # Window expired -> re-fetch, logged as a deliberate retry.
  injects_before=$(count_lines "$op_log" '^inject$')
  if ! run_all_mode "$case_dir" "$cache_dir" "$bin_dir" run4 OP_PREFLIGHT_FIREBASE_PROJECT_ID=other-project \
       OP_PREFLIGHT_DEPLOY_DEGRADED_BACKOFF_SECONDS=0; then
    fail "all-degraded: --mode all after the backoff window failed; stderr=$(cat "$case_dir/run4.err")"
    return
  fi
  if [ "$(count_lines "$op_log" '^inject$')" != "$((injects_before + 1))" ] \
     || ! tail -1 "$bio_log" | grep -q 'reason=deploy-degraded-retry'; then
    fail "all-degraded: expired window did not re-fetch as deploy-degraded-retry; bio=$(cat "$bio_log")"
    return
  fi
  pass "test_all_mode_degraded_deploy_does_not_reprompt: expired backoff window re-fetches (reason=deploy-degraded-retry)"
}

# ---------------------------------------------------------------------------
# test_all_mode_rejects_review_only_cache (friends-and-family-billing#227
# round 3): a review-only cache must never satisfy `--mode all`, even though
# `all` may now accept a DEGRADED cache. The difference is the marker: a
# review cache never attempted deploy creds, so `all` must fetch them.
# ---------------------------------------------------------------------------
test_all_mode_rejects_review_only_cache() {
  local case_dir="$WORKDIR/all-rejects-review"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin" op_log="$case_dir/op.log"
  mkdir -p "$bin_dir"
  make_fresh_cache "$cache_dir" claude "rev-only-pat" "auth-only-pat"
  make_degraded_op_stub "$bin_dir" "$op_log"
  if ! run_all_mode "$case_dir" "$cache_dir" "$bin_dir" run; then
    fail "test_all_mode_rejects_review_only_cache: --mode all failed; stderr=$(cat "$case_dir/run.err")"
    return
  fi
  if [ "$(count_lines "$op_log" '^inject$')" != "1" ] || ! grep -q '^read$' "$op_log"; then
    fail "test_all_mode_rejects_review_only_cache: --mode all served a review-only cache without fetching deploy creds; op=$(cat "$op_log" 2>/dev/null)"
    return
  fi
  if ! grep -q 'reason=cross-mode-invalidation' "$cache_dir/biometric-log"; then
    fail "test_all_mode_rejects_review_only_cache: refetch not logged as cross-mode-invalidation"
    return
  fi
  pass "test_all_mode_rejects_review_only_cache: review-only cache still cannot satisfy --mode all (#227 r3)"
}

# ---------------------------------------------------------------------------
# test_all_mode_alternating_firebase_projects_do_not_evict: two sessions for
# the same agent in two Firebase repos (nathanpaynedotcom and
# fiveacross/gaycruisebingo on 2026-09-24) used to share ONE deploy slot and
# ONE SA key file. Each `--mode all` saw the other project's key, treated it
# as a miss, re-prompted biometric, and overwrote the shared key file under
# the path the other session had exported. Per-project slots: alternating
# A, B, A, B, A, B costs exactly one fetch per project, and B's fetch never
# touches A's key file.
# ---------------------------------------------------------------------------
test_all_mode_alternating_firebase_projects_do_not_evict() {
  local case_dir="$WORKDIR/all-alternating"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin" op_log="$case_dir/op.log"
  local proj
  mkdir -p "$cache_dir" "$bin_dir"
  for proj in proj-alpha proj-beta; do
    mkdir -p "$case_dir/$proj"
    printf '{ "projects": { "default": "%s" } }\n' "$proj" > "$case_dir/$proj/.firebaserc"
  done

  # op stub: inject -> PATs; `document get "<project> — Firebase Deployer SA
  # Key"` -> a well-formed SA key for THAT project; read -> the CF token.
  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${1:-} \${3:-}" >> "$op_log"
case "\${1:-}" in
  inject)
    printf '%s\n' "REVIEWER_PAT=alt-reviewer-pat" "AUTHOR_PAT=alt-author-pat"
    ;;
  document)
    project="\${3%% *}"
    out_path=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--out-file" ]; then shift; out_path="\$1"; fi
      shift || true
    done
    [ -n "\$out_path" ] || exit 1
    printf '{"type": "service_account", "project_id": "%s", "client_email": "firebase-deployer@%s.iam.gserviceaccount.com"}\n' \
      "\$project" "\$project" > "\$out_path"
    ;;
  read)
    printf '%s\n' "alt-cf-token"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  local round
  for round in 1 2 3; do
    for proj in proj-alpha proj-beta; do
      if ! run_all_mode "$case_dir/$proj" "$cache_dir" "$bin_dir" "run-$round"; then
        fail "all-alternating: --mode all in $proj (round $round) failed; stderr=$(cat "$case_dir/$proj/run-$round.err")"
        return
      fi
      if ! grep -q "export OP_PREFLIGHT_FIREBASE_PROJECT=$proj" "$case_dir/$proj/run-$round.out"; then
        fail "all-alternating: $proj (round $round) did not export its own project; out=$(grep -v PAT "$case_dir/$proj/run-$round.out")"
        return
      fi
      # Remember every key path handed to this project's session.
      sed -n "s/^export GOOGLE_APPLICATION_CREDENTIALS=//p" "$case_dir/$proj/run-$round.out" >> "$case_dir/$proj.gac-paths"
    done
  done

  # Every path a session was handed must STILL hold that session's key after
  # the other project fetched (the shared-file swap).
  local gac_path
  for proj in proj-alpha proj-beta; do
    while IFS= read -r gac_path; do
      if ! grep -q "firebase-deployer@$proj.iam" "$gac_path" 2>/dev/null; then
        fail "all-alternating: $proj's exported GOOGLE_APPLICATION_CREDENTIALS ($gac_path) no longer holds $proj's key"
        return
      fi
    done < "$case_dir/$proj.gac-paths"
  done

  if [ "$(count_lines "$op_log" '^inject')" != "2" ] || [ "$(count_lines "$op_log" '^document')" != "2" ]; then
    fail "all-alternating: expected one fetch per project across 6 alternating runs; op log: $(tr '\n' '|' < "$op_log")"
    return
  fi
  if [ "$(count_lines "$cache_dir/biometric-log" 'mode=all')" != "2" ]; then
    fail "all-alternating: expected exactly 2 biometric-log entries; got $(cat "$cache_dir/biometric-log")"
    return
  fi
  pass "test_all_mode_alternating_firebase_projects_do_not_evict: A/B/A/B/A/B costs one fetch per project, keys never swapped"

  # Slots are replaced by rename, never rewritten in place (a concurrent
  # reader must not source a half-written slot): a fresh fetch gives the
  # slot a new inode.
  local slot_path="$cache_dir/op-preflight-claude-deploy-fb-proj-alpha.slot" inode_before inode_after
  inode_before=$(stat -c %i "$slot_path" 2>/dev/null || stat -f %i "$slot_path")
  (cd "$case_dir/proj-alpha" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode all --skip-ssh --refresh >/dev/null 2>&1)
  inode_after=$(stat -c %i "$slot_path" 2>/dev/null || stat -f %i "$slot_path")
  if [ -z "$inode_after" ] || [ "$inode_before" = "$inode_after" ]; then
    fail "all-alternating: a refetch rewrote the deploy slot in place (inode $inode_before -> $inode_after)"
    return
  fi
  pass "test_all_mode_alternating_firebase_projects_do_not_evict: deploy slots are replaced atomically (rename)"

  # Deploy slots must not break helper agent discovery, which auto-sources
  # the PAT cache from the ONE `op-preflight-*.env` in the cache dir.
  local discovered
  # shellcheck disable=SC2016  # $1 expands in the child bash, by design
  discovered=$(env -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    bash -c 'source "$1" && preflight_agent' _ "$ROOT/scripts/lib/preflight-helpers.sh" 2>/dev/null || true)
  if [ "$discovered" != "claude" ]; then
    fail "all-alternating: preflight_agent discovered '$discovered' (want claude) with deploy slots present: $(ls "$cache_dir")"
    return
  fi
  pass "test_all_mode_alternating_firebase_projects_do_not_evict: deploy slots do not break helper agent discovery"

  # A `--mode review --refresh` rewrites the main session file (PATs only);
  # the deploy slot, CF_API_TOKEN included, must survive it intact.
  local injects_before
  injects_before=$(count_lines "$op_log" '^inject')
  (cd "$case_dir/proj-alpha" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode review --refresh --skip-ssh >/dev/null 2>&1)
  if ! run_all_mode "$case_dir/proj-alpha" "$cache_dir" "$bin_dir" run-after-review; then
    fail "all-alternating: --mode all after a review refresh failed; stderr=$(cat "$case_dir/proj-alpha/run-after-review.err")"
    return
  fi
  if [ "$(count_lines "$op_log" '^inject')" != "$((injects_before + 1))" ] \
     || ! grep -q "^export CF_API_TOKEN=alt-cf-token$" "$case_dir/proj-alpha/run-after-review.out"; then
    fail "all-alternating: a review refresh cost the deploy slot its CF_API_TOKEN or forced a re-fetch; op=$(tr '\n' '|' < "$op_log")"
    return
  fi
  pass "test_all_mode_alternating_firebase_projects_do_not_evict: a review refresh leaves the deploy slot (CF_API_TOKEN included) intact"

  # A slot past the session TTL is not honoured even though it exists and
  # the main session file is still fresh: age only the slot's own epoch.
  local slot="$cache_dir/op-preflight-claude-deploy-fb-proj-alpha.slot"
  sed "s/^OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=.*/OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=1/" "$slot" > "$slot.tmp" && mv "$slot.tmp" "$slot"
  injects_before=$(count_lines "$op_log" '^inject')
  if ! run_all_mode "$case_dir/proj-alpha" "$cache_dir" "$bin_dir" run-ttl; then
    fail "all-alternating: TTL=0 run failed; stderr=$(cat "$case_dir/proj-alpha/run-ttl.err")"
    return
  fi
  if [ "$(count_lines "$op_log" '^inject')" != "$((injects_before + 1))" ]; then
    fail "all-alternating: an expired deploy slot was served from cache"
    return
  fi
  pass "test_all_mode_alternating_firebase_projects_do_not_evict: an expired deploy slot re-fetches"

  # --purge removes every slot and per-project key file for the agent.
  PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" "$SCRIPT" --agent claude --purge 2>/dev/null
  local leftover
  for leftover in "$cache_dir"/op-preflight-claude-deploy-* "$cache_dir"/op-preflight-claude-firebase-sa*; do
    if [ -e "$leftover" ]; then
      fail "all-alternating: --purge left $leftover behind"
      return
    fi
  done
  pass "test_all_mode_alternating_firebase_projects_do_not_evict: --purge removes per-project slots and keys"
}

# ---------------------------------------------------------------------------
# test_failed_fetch_does_not_evict_shared_deploy_files (CodeRabbit on #1318):
# the ADC file is shared by every context that resolves to ADC, and a
# project's SA file by every session of that project. A failed fetch used to
# truncate (`>`) and then `rm` the file in place, deleting a credential
# another session had already exported. Fetches now stage and move into
# place only on success.
# ---------------------------------------------------------------------------
test_failed_fetch_does_not_evict_shared_deploy_files() {
  local case_dir="$WORKDIR/no-evict-shared"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin"
  local adc_ok="$case_dir/adc-ok" sa_ok="$case_dir/sa-ok"
  mkdir -p "$cache_dir" "$bin_dir" "$case_dir/no-firebase" "$case_dir/proj-gamma" "$case_dir/proj-delta"
  printf '{ "projects": { "default": "proj-gamma" } }\n' > "$case_dir/proj-gamma/.firebaserc"
  printf '{ "projects": { "default": "proj-delta" } }\n' > "$case_dir/proj-delta/.firebaserc"

  # op stub: ADC read and SA document get succeed only while their toggle
  # file exists; the ADC is a self-contained service_account (no network).
  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  inject)
    printf '%s\n' "REVIEWER_PAT=ne-reviewer-pat" "AUTHOR_PAT=ne-author-pat"
    ;;
  read)
    if [ "\${2:-}" = "op://Private/test-no-evict-adc/credential" ] && [ -e "$adc_ok" ]; then
      printf '{"type": "service_account", "client_email": "shared-adc@example.iam.gserviceaccount.com"}\n'
      exit 0
    fi
    exit 1
    ;;
  document)
    [ -e "$sa_ok" ] || exit 1
    project="\${3%% *}"
    out_path=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--out-file" ]; then shift; out_path="\$1"; fi
      shift || true
    done
    printf '{"type": "service_account", "client_email": "firebase-deployer@%s.iam.gserviceaccount.com"}\n' "\$project" > "\$out_path"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/op"

  run_ne() { # <dir> <label> [--refresh]
    local dir="$1" label="$2"
    shift 2
    (cd "$dir" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="op://Private/test-no-evict-adc/credential" \
      "$SCRIPT" --agent claude --mode all --skip-ssh "$@" >"$dir/$label.out" 2>"$dir/$label.err")
  }

  # 1. A repo without Firebase loads the shared ADC and exports its path.
  touch "$adc_ok"
  if ! run_ne "$case_dir/no-firebase" adc-load; then
    fail "no-evict: ADC load failed; stderr=$(cat "$case_dir/no-firebase/adc-load.err")"
    return
  fi
  local adc_path
  adc_path=$(sed -n "s/^export GOOGLE_APPLICATION_CREDENTIALS=//p" "$case_dir/no-firebase/adc-load.out")
  # 2. A Firebase project with no SA key falls back to ADC, which now fails.
  rm -f "$adc_ok"
  if ! run_ne "$case_dir/proj-delta" adc-fail; then
    fail "no-evict: degraded --mode all in proj-delta failed; stderr=$(cat "$case_dir/proj-delta/adc-fail.err")"
    return
  fi
  if [ -z "$adc_path" ] || ! grep -q "shared-adc@" "$adc_path" 2>/dev/null; then
    fail "no-evict: a failed ADC fetch in another context deleted or truncated the shared ADC file ($adc_path)"
    return
  fi
  pass "test_failed_fetch_does_not_evict_shared_deploy_files: a failed ADC fetch leaves the shared ADC file intact"

  # 3. Same project: a loaded SA key survives a failed --refresh of that project.
  touch "$sa_ok"
  if ! run_ne "$case_dir/proj-gamma" sa-load; then
    fail "no-evict: SA load failed; stderr=$(cat "$case_dir/proj-gamma/sa-load.err")"
    return
  fi
  local sa_path
  sa_path=$(sed -n "s/^export GOOGLE_APPLICATION_CREDENTIALS=//p" "$case_dir/proj-gamma/sa-load.out")
  rm -f "$sa_ok"
  run_ne "$case_dir/proj-gamma" sa-fail --refresh || true
  if [ -z "$sa_path" ] || ! grep -q "firebase-deployer@proj-gamma" "$sa_path" 2>/dev/null; then
    fail "no-evict: a failed SA refetch deleted or truncated proj-gamma's exported key ($sa_path)"
    return
  fi
  local staged
  for staged in "$cache_dir"/*.staged.*; do
    if [ -e "$staged" ]; then
      fail "no-evict: a staged download was left behind: $staged"
      return
    fi
  done
  pass "test_failed_fetch_does_not_evict_shared_deploy_files: a failed SA refetch leaves the exported key intact, no staged leftovers"

  # 4. A failed `--mode deploy --refresh` (key rotated or revoked) must
  #    invalidate proj-gamma's slot, so the next plain `--mode deploy` does
  #    not silently re-export the old key -- while the key FILE itself stays
  #    for shells already using it.
  run_deploy() { # <label> [--refresh]
    local label="$1"
    shift
    (cd "$case_dir/proj-gamma" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      GCP_ADC_OP_URI="op://Private/test-no-evict-adc/credential" \
      "$SCRIPT" --agent claude --mode deploy "$@" >"$case_dir/proj-gamma/$label.out" 2>"$case_dir/proj-gamma/$label.err")
  }
  touch "$sa_ok"
  if ! run_deploy deploy-load; then
    fail "no-evict: --mode deploy load failed; stderr=$(cat "$case_dir/proj-gamma/deploy-load.err")"
    return
  fi
  sa_path=$(sed -n "s/^export GOOGLE_APPLICATION_CREDENTIALS=//p" "$case_dir/proj-gamma/deploy-load.out")
  rm -f "$sa_ok" "$adc_ok"
  if run_deploy deploy-refresh-fail --refresh; then
    fail "no-evict: --mode deploy --refresh with no credential available succeeded"
    return
  fi
  if run_deploy deploy-after-fail; then
    fail "no-evict: after a failed --refresh, plain --mode deploy re-exported the old key from the slot; out=$(cat "$case_dir/proj-gamma/deploy-after-fail.out")"
    return
  fi
  if [ ! -s "$sa_path" ]; then
    fail "no-evict: the failed refresh deleted the key file ($sa_path) shells may still be using"
    return
  fi
  pass "test_failed_fetch_does_not_evict_shared_deploy_files: a failed deploy --refresh invalidates the slot but keeps the key file"

  # 5. Propagation skew: a pre-slot consumer left deploy fields for this
  #    project in the shared session file. After a failed --refresh those
  #    must not be the fallback either -- while the PATs survive.
  touch "$sa_ok"
  if ! run_deploy deploy-reload; then
    fail "no-evict: --mode deploy reload failed; stderr=$(cat "$case_dir/proj-gamma/deploy-reload.err")"
    return
  fi
  make_aged_cache "$cache_dir" claude 0 "ne-reviewer-pat" "ne-author-pat"
  printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_FIREBASE_SA_TMPFILE=%s\nOP_PREFLIGHT_FIREBASE_PROJECT=proj-gamma\n' \
    "$sa_path" "$sa_path" >> "$cache_dir/op-preflight-claude.env"
  rm -f "$sa_ok" "$adc_ok"
  run_deploy deploy-refresh-fail-2 --refresh || true
  if run_deploy deploy-after-fail-2; then
    fail "no-evict: after a failed --refresh, plain --mode deploy fell back to pre-slot session deploy fields; out=$(cat "$case_dir/proj-gamma/deploy-after-fail-2.out")"
    return
  fi
  if ! grep -q '^OP_PREFLIGHT_REVIEWER_PAT=ne-reviewer-pat$' "$cache_dir/op-preflight-claude.env"; then
    fail "no-evict: invalidating deploy fields dropped the cached PATs from the session file"
    return
  fi
  pass "test_failed_fetch_does_not_evict_shared_deploy_files: a failed deploy --refresh also strips pre-slot session deploy fields, PATs kept"

  # 6. ...but only the failing context's: another project's pre-slot entry
  #    in the shared session file survives proj-gamma's failed refresh.
  make_aged_cache "$cache_dir" claude 0 "ne-reviewer-pat" "ne-author-pat"
  printf 'GOOGLE_APPLICATION_CREDENTIALS=/tmp/proj-omega-key.json\nOP_PREFLIGHT_FIREBASE_SA_TMPFILE=/tmp/proj-omega-key.json\nOP_PREFLIGHT_FIREBASE_PROJECT=proj-omega\n' \
    >> "$cache_dir/op-preflight-claude.env"
  run_deploy deploy-refresh-fail-3 --refresh || true
  if ! grep -q '^OP_PREFLIGHT_FIREBASE_PROJECT=proj-omega$' "$cache_dir/op-preflight-claude.env"; then
    fail "no-evict: proj-gamma's failed refresh stripped proj-omega's pre-slot session entry"
    return
  fi
  pass "test_failed_fetch_does_not_evict_shared_deploy_files: a failed refresh strips only its own context's pre-slot entry"

  # 7. Pre-slot shared ADC is never a Firebase project's credential: after
  #    proj-gamma's failed refresh removes its slot, a plain deploy must not
  #    fall back to a pre-slot ADC entry in the session file.
  make_aged_cache "$cache_dir" claude 0 "ne-reviewer-pat" "ne-author-pat"
  printf '{"type": "service_account", "client_email": "shared-adc@example.iam.gserviceaccount.com"}\n' > "$cache_dir/legacy-adc.json"
  printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_ADC_TMPFILE=%s\n' "$cache_dir/legacy-adc.json" "$cache_dir/legacy-adc.json" \
    >> "$cache_dir/op-preflight-claude.env"
  run_deploy deploy-refresh-fail-4 --refresh || true
  if run_deploy deploy-after-fail-4; then
    fail "no-evict: after a failed --refresh in proj-gamma, plain --mode deploy reused pre-slot shared ADC; out=$(grep -v PAT "$case_dir/proj-gamma/deploy-after-fail-4.out")"
    return
  fi
  pass "test_failed_fetch_does_not_evict_shared_deploy_files: pre-slot shared ADC is never reused for a Firebase project"
}

# ---------------------------------------------------------------------------
# test_check_selects_same_deploy_context_without_python (Codex on #1318):
# the full-fetch writer and --check must pick the SAME deploy slot. With a
# broken python3 the writer's python .firebaserc parser used to see no
# project (-> the `adc` slot) while --check's probe-free parser saw the
# project (-> its `fb-*` slot), so --check --mode all reported the cache
# incomplete on exactly the hosts its no-python path exists for.
# ---------------------------------------------------------------------------
test_check_selects_same_deploy_context_without_python() {
  local case_dir="$WORKDIR/no-python-context"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin" op_log="$case_dir/op.log"
  mkdir -p "$cache_dir" "$bin_dir"
  printf '{ "projects": { "default": "proj-epsilon" } }\n' > "$case_dir/.firebaserc"
  make_degraded_op_stub "$bin_dir" "$op_log"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin_dir/python3"
  chmod +x "$bin_dir/python3"

  if ! run_all_mode "$case_dir" "$cache_dir" "$bin_dir" run; then
    fail "no-python-context: --mode all failed; stderr=$(cat "$case_dir/run.err")"
    return
  fi
  local rc=0
  (cd "$case_dir" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode all --check >/dev/null 2>"$case_dir/check.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "no-python-context: --check --mode all looked in a different slot than the writer used; slots: $(cd "$cache_dir" && echo op-preflight-*) stderr=$(cat "$case_dir/check.err")"
    return
  fi
  pass "test_check_selects_same_deploy_context_without_python: writer and --check agree on the deploy slot"
}

# ---------------------------------------------------------------------------
# test_deploy_failure_clears_inherited_credentials (Codex on #1318): a failed
# `--mode deploy` used to print nothing, so `eval "$(...)"` returned 0 and the
# caller kept an earlier project's GOOGLE_APPLICATION_CREDENTIALS -- now a
# live per-project key -- and deployed project B as project A. The failure
# output must clear the deploy variables AND fail the eval.
# ---------------------------------------------------------------------------
test_deploy_failure_clears_inherited_credentials() {
  local case_dir="$WORKDIR/deploy-fail-clears"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin"
  mkdir -p "$cache_dir" "$bin_dir"
  printf '{ "projects": { "default": "proj-zeta" } }\n' > "$case_dir/.firebaserc"
  make_degraded_op_stub "$bin_dir" "$case_dir/op.log"
  printf '{"type": "service_account", "client_email": "firebase-deployer@proj-a.iam.gserviceaccount.com"}\n' > "$case_dir/proj-a-key.json"

  local result
  # A key an earlier preflight eval exported: its marker proves ownership.
  # shellcheck disable=SC2016  # expanded by the child bash, by design
  result=$(cd "$case_dir" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    GCP_ADC_OP_URI="op://Private/test-deploy-fail-adc/credential" \
    GOOGLE_APPLICATION_CREDENTIALS="$case_dir/proj-a-key.json" \
    OP_PREFLIGHT_FIREBASE_SA_TMPFILE="$case_dir/proj-a-key.json" OP_PREFLIGHT_FIREBASE_PROJECT=proj-a \
    bash -c 'f() { eval "$("$@" 2>/dev/null)"; }; f "$@"; printf "%s|%s" "$?" "${GOOGLE_APPLICATION_CREDENTIALS:-}"' \
    _ "$SCRIPT" --agent claude --mode deploy)
  if [ "${result%%|*}" = "0" ]; then
    fail "deploy-fail-clears: eval of a failed --mode deploy returned 0 (result=$result)"
    return
  fi
  if [ -n "${result#*|}" ]; then
    fail "deploy-fail-clears: a failed --mode deploy left GOOGLE_APPLICATION_CREDENTIALS=${result#*|} (another project's key) set"
    return
  fi
  # A human override (no preflight marker) survives; the eval still fails.
  # shellcheck disable=SC2016  # expanded by the child bash, by design
  result=$(cd "$case_dir" && env -u OP_PREFLIGHT_ADC_TMPFILE -u OP_PREFLIGHT_FIREBASE_SA_TMPFILE \
    PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    GCP_ADC_OP_URI="op://Private/test-deploy-fail-adc/credential" \
    GOOGLE_APPLICATION_CREDENTIALS="$case_dir/human-override.json" \
    bash -c 'f() { eval "$("$@" 2>/dev/null)"; }; f "$@"; printf "%s|%s" "$?" "${GOOGLE_APPLICATION_CREDENTIALS:-}"' \
    _ "$SCRIPT" --agent claude --mode deploy)
  if [ "${result%%|*}" = "0" ] || [ "${result#*|}" != "$case_dir/human-override.json" ]; then
    fail "deploy-fail-clears: a failed --mode deploy must fail the eval but keep a human override (result=$result)"
    return
  fi
  pass "test_deploy_failure_clears_inherited_credentials: failed --mode deploy clears preflight-owned creds, keeps a human override, fails the eval"
}

# ---------------------------------------------------------------------------
# test_firebaserc_parsers_agree (Codex on #1318): the probe-free .firebaserc
# parser picks the deploy slot AND the SA key to fetch, so it must read the
# root `projects.default` exactly as the python parser (and the Firebase CLI)
# does. A first-textual-match regex returned a nested "projects" object's
# default and cached another project's key. Both real functions are lifted
# out of the script and must agree on every case, including the failures.
# ---------------------------------------------------------------------------
test_firebaserc_parsers_agree() {
  local case_dir="$WORKDIR/firebaserc-parity"
  mkdir -p "$case_dir"
  awk '/^(detect_firebase_project|firebaserc_default_project_no_python)\(\) \{/,/^\}/' "$SCRIPT" > "$case_dir/parsers.sh"

  local -a cases=(
    'simple|{ "projects": { "default": "right" } }'
    'nested-projects-first|{ "targets": { "x": { "projects": { "default": "wrong" } } }, "projects": { "default": "right" } }'
    'nested-in-array|{ "list": [ { "projects": { "default": "wrong" } } ], "projects": { "default": "right" } }'
    'braces-in-string|{ "note": "{\"projects\": {\"default\": \"wrong\"}}", "projects": { "default": "right" } }'
    'escaped-quote-key|{ "etags": { "a\"b": "c" }, "projects": { "prod": "p", "default": "right" } }'
    'nested-object-in-projects|{ "projects": { "meta": { "default": "wrong" }, "default": "right" } }'
    $'multiline|{\n  "projects": {\n    "default": "right"\n  }\n}'
    'duplicate-projects|{ "projects": { "default": "first" }, "projects": { "default": "second" } }'
    'duplicate-default|{ "projects": { "default": "first", "default": "second" } }'
    'later-projects-string|{ "projects": { "default": "first" }, "projects": "x" }'
    'no-default|{ "projects": { "prod": "p" } }'
    'numeric-default|{ "projects": { "default": 5 } }'
    'empty-default|{ "projects": { "default": "" } }'
    'no-projects|{ "targets": { "projects": { "default": "wrong" } } }'
    'unicode-escape-ascii|{ "projects": { "default": "proj\u002dalpha" } }'
    'escaped-slash-and-tab|{ "projects": { "default": "a\/b\tc" } }'
    'escaped-key|{ "pro\u006aects": { "def\u0061ult": "right" } }'
    'unicode-escape-bmp|{ "projects": { "default": "caf\u00e9" } }'
    'surrogate-pair|{ "projects": { "default": "x\ud83d\ude00y" } }'
    'lone-surrogate|{ "projects": { "default": "x\ud83dy" } }'
    'invalid-escape|{ "projects": { "default": "a\qb" } }'
    'lone-surrogate-in-root-key|{ "pro\ud800jects": { "default": "wrong" }, "x": 1 }'
    'lone-surrogate-in-default-key|{ "projects": { "def\udc00ault": "wrong", "default": "right" } }'
    'lone-surrogate-key-only|{ "projects": { "def\ud800ault": "wrong" } }'
    'nul-in-root-key|{ "pro\u0000jects": { "default": "wrong" } }'
    'nul-in-default-value|{ "projects": { "default": "prod\u0000evil" } }'
    'newline-in-default-value|{ "projects": { "default": "a\nb" } }'
    'del-in-default-value|{ "projects": { "default": "a\u007fb" } }'
    'truncated-then-garbage|{"projects":{"default":"prod"}} BROKEN'
    'unclosed-root|{"projects":{"default":"prod"}'
    'trailing-comma|{"projects":{"default":"prod",}}'
    'line-comment|{"projects":{"default":"prod"}} // note'
    'two-top-level-values|{"projects":{"default":"prod"}} {}'
    'missing-colon|{"projects" {"default":"prod"}}'
    'leading-zero-number|{"n": 01, "projects":{"default":"prod"}}'
    'trailing-dot-number|{"n": 1., "projects":{"default":"prod"}}'
    'plus-number|{"n": +1, "projects":{"default":"prod"}}'
    'python-literals-ok|{"n": NaN, "m": -Infinity, "o": Infinity, "projects":{"default":"prod"}}'
    'numbers-and-literals-ok|{"n": [-0, 1.5e3, 2E-2, 0.25, true, false, null, []], "projects":{"default":"prod"}}'
    'top-level-array|[{"projects":{"default":"prod"}}]'
    'top-level-scalar|"prod"'
    'empty|'
  )
  local entry name json py awkv
  # shellcheck disable=SC2016  # "$1" expands in the child bash, by design
  for entry in "${cases[@]}"; do
    name="${entry%%|*}"
    json="${entry#*|}"
    mkdir -p "$case_dir/$name"
    printf '%s\n' "$json" > "$case_dir/$name/.firebaserc"
    py=$(cd "$case_dir/$name" && env -u OP_PREFLIGHT_FIREBASE_PROJECT_ID bash -c '. "$1"; detect_firebase_project' _ "$case_dir/parsers.sh" 2>/dev/null || true)
    awkv=$(cd "$case_dir/$name" && bash -c '. "$1"; firebaserc_default_project_no_python' _ "$case_dir/parsers.sh" 2>/dev/null || true)
    if [ "$py" != "$awkv" ]; then
      fail "firebaserc-parity[$name]: python parser '$py' != no-python parser '$awkv'"
      return
    fi
  done
  # Raw-byte cases need printf's octal escapes in the FORMAT (so '%' is never
  # in these fixtures): a raw control character, valid and invalid UTF-8
  # (bad lead byte, overlong, UTF-8-encoded surrogate) and a leading BOM.
  local -a raw_cases=(
    'raw-control-char|{"projects":{"default":"pr\001od"}}'
    'raw-valid-utf8|{"projects":{"default":"caf\303\251"}}'
    'raw-invalid-lead-byte|{"note":"\377","projects":{"default":"prod"}}'
    'raw-overlong|{"note":"\300\257","projects":{"default":"prod"}}'
    'raw-encoded-surrogate|{"note":"\355\240\200","projects":{"default":"prod"}}'
    'raw-truncated-sequence|{"note":"\342\202","projects":{"default":"prod"}}'
    'raw-bom|\357\273\277{"projects":{"default":"prod"}}'
  )
  # shellcheck disable=SC2016  # "$1" expands in the child bash, by design
  for entry in "${raw_cases[@]}"; do
    name="${entry%%|*}"
    json="${entry#*|}"
    mkdir -p "$case_dir/$name"
    # shellcheck disable=SC2059  # the fixture IS the format: octal escapes, no '%'
    printf "$json\n" > "$case_dir/$name/.firebaserc"
    py=$(cd "$case_dir/$name" && env -u OP_PREFLIGHT_FIREBASE_PROJECT_ID bash -c '. "$1"; detect_firebase_project' _ "$case_dir/parsers.sh" 2>/dev/null || true)
    awkv=$(cd "$case_dir/$name" && bash -c '. "$1"; firebaserc_default_project_no_python' _ "$case_dir/parsers.sh" 2>/dev/null || true)
    if [ "$py" != "$awkv" ]; then
      fail "firebaserc-parity[$name]: python parser '$py' != no-python parser '$awkv'"
      return
    fi
  done
  pass "test_firebaserc_parsers_agree: no-python .firebaserc parser matches the python parser on $(( ${#cases[@]} + ${#raw_cases[@]} )) cases"
}

# ---------------------------------------------------------------------------
# test_newer_pre_slot_write_supersedes_slot (Codex on #1318): during
# propagation skew an older consumer's op-preflight.sh still writes deploy
# fields into the shared session file and never touches slots. A newer such
# write must win over an older slot (else a rotated key or a recovered
# credential is ignored until the slot expires); an older one must not.
# ---------------------------------------------------------------------------
test_newer_pre_slot_write_supersedes_slot() {
  local case_dir="$WORKDIR/legacy-vs-slot"
  local cache_dir="$case_dir/cache" adc_file="$case_dir/cache/legacy-adc.json"
  local slot="$case_dir/cache/op-preflight-claude-deploy-adc.slot"
  local label session_age slot_age out rc
  mkdir -p "$case_dir/repo"
  for label in newer older; do
    rm -rf "$cache_dir"
    if [ "$label" = newer ]; then session_age=0; slot_age=300; else session_age=300; slot_age=0; fi
    make_aged_cache "$cache_dir" claude "$session_age" "lv-reviewer-pat" "lv-author-pat"
    printf '{"type": "service_account", "client_email": "legacy@example.iam.gserviceaccount.com"}\n' > "$adc_file"
    printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_ADC_TMPFILE=%s\n' "$adc_file" "$adc_file" \
      >> "$cache_dir/op-preflight-claude.env"
    printf "OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=%s\nOP_PREFLIGHT_DEPLOY_CONTEXT=''\nOP_PREFLIGHT_DEPLOY_DEGRADED=1\nOP_PREFLIGHT_DEPLOY_DEGRADED_AT_EPOCH=%s\n" \
      "$(( $(date +%s) - slot_age ))" "$(( $(date +%s) - slot_age ))" > "$slot"
    rc=0
    out=$(cd "$case_dir/repo" && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      "$SCRIPT" --agent claude --mode all --skip-ssh 2>"$case_dir/$label.err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      fail "legacy-vs-slot[$label]: --mode all failed (op must not be needed); stderr=$(cat "$case_dir/$label.err")"
      return
    fi
    if [ "$label" = newer ] && ! printf '%s\n' "$out" | grep -q "^export GOOGLE_APPLICATION_CREDENTIALS=$adc_file$"; then
      fail "legacy-vs-slot[newer]: a newer pre-slot write did not supersede an older degraded slot; out=$(printf '%s\n' "$out" | grep -v PAT)"
      return
    fi
    if [ "$label" = older ] && printf '%s\n' "$out" | grep -q "^export GOOGLE_APPLICATION_CREDENTIALS="; then
      fail "legacy-vs-slot[older]: an older pre-slot write overrode a newer slot; out=$(printf '%s\n' "$out" | grep -v PAT)"
      return
    fi
  done
  # ...but only for the SAME context. In a Firebase repo with a valid project
  # SA slot, a newer pre-slot write of shared ADC or of ANOTHER project's SA
  # must not displace the slot (no swap to ADC, no refetch: op aborts here).
  local fb_slot="$cache_dir/op-preflight-claude-deploy-fb-proj-kappa.slot" sa_file="$cache_dir/kappa-sa.json" variant
  mkdir -p "$case_dir/kappa"
  printf '{ "projects": { "default": "proj-kappa" } }\n' > "$case_dir/kappa/.firebaserc"
  for variant in adc other-project-sa; do
    rm -rf "$cache_dir"
    make_aged_cache "$cache_dir" claude 0 "lv-reviewer-pat" "lv-author-pat"
    printf '{"type": "service_account", "client_email": "firebase-deployer@proj-kappa.iam.gserviceaccount.com"}\n' > "$sa_file"
    printf '{"type": "service_account", "client_email": "legacy@example.iam.gserviceaccount.com"}\n' > "$adc_file"
    if [ "$variant" = adc ]; then
      printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_ADC_TMPFILE=%s\n' "$adc_file" "$adc_file" >> "$cache_dir/op-preflight-claude.env"
    else
      printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_FIREBASE_SA_TMPFILE=%s\nOP_PREFLIGHT_FIREBASE_PROJECT=proj-other\n' "$adc_file" "$adc_file" >> "$cache_dir/op-preflight-claude.env"
    fi
    printf "OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=%s\nOP_PREFLIGHT_DEPLOY_CONTEXT=proj-kappa\nGOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_FIREBASE_SA_TMPFILE=%s\nOP_PREFLIGHT_FIREBASE_PROJECT=proj-kappa\n" \
      "$(( $(date +%s) - 300 ))" "$sa_file" "$sa_file" > "$fb_slot"
    rc=0
    out=$(cd "$case_dir/kappa" && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      "$SCRIPT" --agent claude --mode all --skip-ssh 2>"$case_dir/kappa-$variant.err") || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -q "^export GOOGLE_APPLICATION_CREDENTIALS=$sa_file$"; then
      fail "legacy-vs-slot[$variant]: a newer pre-slot write for another context displaced proj-kappa's SA slot (rc=$rc); out=$(printf '%s\n' "$out" | grep -v PAT) err=$(cat "$case_dir/kappa-$variant.err")"
      return
    fi
  done
  pass "test_newer_pre_slot_write_supersedes_slot: newer pre-slot deploy fields win, older ones do not, other contexts never"
}

# ---------------------------------------------------------------------------
# test_firebaserc_project_cannot_inject_into_slot (Phase 4b on #1318, P1): the
# slot is SOURCED on the next read, and a .firebaserc project decoded from
# JSON escapes can contain newlines. Written raw into the slot's header
# comment, `"x\n<command>\n#"` became executable lines, run with the cached
# PATs loaded. Both parsers now reject control characters in a project, and
# the slot never carries a raw value.
# ---------------------------------------------------------------------------
test_firebaserc_project_cannot_inject_into_slot() {
  local case_dir="$WORKDIR/slot-injection"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin" marker="$case_dir/INJECTED" f line
  mkdir -p "$cache_dir" "$bin_dir"
  make_degraded_op_stub "$bin_dir" "$case_dir/op.log"
  printf '{ "projects": { "default": "x\\ntouch %s\\n#" } }\n' "$marker" > "$case_dir/.firebaserc"
  run_all_mode "$case_dir" "$cache_dir" "$bin_dir" first || true
  run_all_mode "$case_dir" "$cache_dir" "$bin_dir" second || true
  (cd "$case_dir" && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode all --check >/dev/null 2>&1) || true
  if [ -e "$marker" ]; then
    fail "slot-injection: a .firebaserc project name executed as shell code"
    return
  fi
  for f in "$cache_dir"/*.slot; do
    [ -e "$f" ] || continue
    while IFS= read -r line; do
      case "$line" in
        '#'*|[A-Z_]*=*) ;;
        *) fail "slot-injection: $f carries a raw non-assignment line: $line"; return ;;
      esac
    done < "$f"
  done
  pass "test_firebaserc_project_cannot_inject_into_slot: an escaped-newline project name is rejected and never reaches the slot raw"
}

# ---------------------------------------------------------------------------
# test_pre_slot_sa_is_never_exported (Phase 4b on #1318, P1): mixed-version
# A/B. Project A (updated checkout) has an isolated slot; an OLDER checkout of
# A then writes a newer session pointing at the one shared pre-slot
# op-preflight-<agent>-firebase-sa.json, which an older checkout of project B
# later overwrites. A must never be handed that shared path: the newer
# pre-slot SA forces a fetch into A's own slot, whose key B cannot touch.
# ---------------------------------------------------------------------------
test_pre_slot_sa_is_never_exported() {
  local case_dir="$WORKDIR/pre-slot-sa"
  local cache_dir="$case_dir/cache" bin_dir="$case_dir/bin" op_log="$case_dir/op.log"
  local shared="$cache_dir/op-preflight-claude-firebase-sa.json" out gac
  mkdir -p "$cache_dir" "$bin_dir" "$case_dir/proj-a"
  printf '{ "projects": { "default": "proj-a" } }\n' > "$case_dir/proj-a/.firebaserc"
  cat > "$bin_dir/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >> "$op_log"
case "\${1:-}" in
  inject) printf '%s\n' "REVIEWER_PAT=ps-reviewer-pat" "AUTHOR_PAT=ps-author-pat" ;;
  document)
    project="\${3%% *}"; out_path=""
    while [ \$# -gt 0 ]; do if [ "\$1" = "--out-file" ]; then shift; out_path="\$1"; fi; shift || true; done
    printf '{"type": "service_account", "client_email": "firebase-deployer@%s.iam.gserviceaccount.com"}\n' "\$project" > "\$out_path"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin_dir/op"

  # 1. Updated checkout of A: isolated slot.
  run_all_mode "$case_dir/proj-a" "$cache_dir" "$bin_dir" first || { fail "pre-slot-sa: first fetch failed"; return; }
  # 2. Older checkout of A: newer pre-slot session entry naming the SHARED file.
  printf '{"type": "service_account", "client_email": "firebase-deployer@proj-a.iam.gserviceaccount.com"}\n' > "$shared"
  sed "s/^OP_PREFLIGHT_CREATED_AT_EPOCH=.*/OP_PREFLIGHT_CREATED_AT_EPOCH=$(( $(date +%s) + 5 ))/" \
    "$cache_dir/op-preflight-claude.env" > "$cache_dir/s.tmp" && mv "$cache_dir/s.tmp" "$cache_dir/op-preflight-claude.env"
  printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\nOP_PREFLIGHT_FIREBASE_SA_TMPFILE=%s\nOP_PREFLIGHT_FIREBASE_PROJECT=proj-a\n' "$shared" "$shared" \
    >> "$cache_dir/op-preflight-claude.env"
  # 3. Updated checkout of A runs again.
  out=$(cd "$case_dir/proj-a" && PATH="$bin_dir:$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent claude --mode all --skip-ssh 2>/dev/null) || { fail "pre-slot-sa: second run failed"; return; }
  gac=$(printf '%s\n' "$out" | sed -n "s/^export GOOGLE_APPLICATION_CREDENTIALS=//p")
  if [ "$gac" = "$shared" ]; then
    fail "pre-slot-sa: the shared pre-slot SA path was exported to project A"
    return
  fi
  # 4. Older checkout of B overwrites the shared file; A's key must be intact.
  printf '{"type": "service_account", "client_email": "firebase-deployer@proj-b.iam.gserviceaccount.com"}\n' > "$shared"
  if [ -z "$gac" ] || ! grep -q "firebase-deployer@proj-a" "$gac"; then
    fail "pre-slot-sa: project A's exported key ($gac) no longer holds A's key after B overwrote the shared file"
    return
  fi
  pass "test_pre_slot_sa_is_never_exported: a newer pre-slot SA forces a project-owned fetch; B's overwrite cannot reach A"
}

test_check_fresh_cache
test_check_missing_cache
test_check_stale_cache
test_check_mutex
test_status_alias
test_check_emits_no_credentials
test_check_compat_guard_fails_closed
test_print_exports_eval_populates_both_vars
test_print_exports_error_paths_fail_closed
test_check_guard_is_injection_safe
test_quiet_mode
test_default_mode_is_review
test_default_ttl_is_ten_hours
test_ttl_override_both_directions
test_check_deploy_no_python3_probe
test_check_deploy_firebase_sa_no_python3_probe
test_check_deploy_firebase_sa_project_mismatch_fails_closed
test_deploy_mode_prefers_firebase_sa_over_gcp_adc
test_deploy_mode_refreshes_unusable_cached_firebase_sa
test_deploy_mode_refreshes_mismatched_cached_firebase_sa
test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch
test_check_review_mode_omits_deploy_creds
test_source_gcp_adc_stale_forces_refresh
test_deploy_mode_requires_agent
test_deploy_full_fetch_fails_closed_on_unreadable_adc
test_deploy_full_fetch_fail_closed_structural
test_check_rejects_cache_from_a_different_pat_item
test_preflight_mode_is_exported
test_all_mode_degraded_deploy_does_not_reprompt
test_all_mode_rejects_review_only_cache
test_all_mode_alternating_firebase_projects_do_not_evict
test_failed_fetch_does_not_evict_shared_deploy_files
test_check_selects_same_deploy_context_without_python
test_deploy_failure_clears_inherited_credentials
test_firebaserc_parsers_agree
test_newer_pre_slot_write_supersedes_slot
test_firebaserc_project_cannot_inject_into_slot
test_pre_slot_sa_is_never_exported

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
