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

# Helper: synthesize a fresh cache file.
make_fresh_cache() {
  local dir="$1" agent="$2" reviewer_pat="$3" author_pat="$4"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local epoch
  epoch=$(date +%s)
  cat > "$dir/op-preflight-$agent.env" <<EOF
# synthetic test cache
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

# Helper: synthesize a STALE cache file (CREATED_AT older than TTL).
make_stale_cache() {
  local dir="$1" agent="$2"
  mkdir -p "$dir"
  chmod 700 "$dir"
  # 5h ago, TTL is 4h
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

# ---------------------------------------------------------------------------
# Test 1: --check with a fresh cache emits exports, never invokes op.
# ---------------------------------------------------------------------------
test_check_fresh_cache() {
  local case_dir="$WORKDIR/case1"
  make_fresh_cache "$case_dir" claude "rev-pat-1" "author-pat-1"

  local out err rc
  out=$(PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_CACHE_DIR="$case_dir" \
    "$SCRIPT" --agent claude --check 2>"$WORKDIR/case1.err") || rc=$?
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
  pass "test_check_fresh_cache: fresh cache emits exports without op/ssh/gh auth switch"
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
  if [ -s "$WORKDIR/case2.out" ]; then
    fail "test_check_missing_cache: expected empty stdout on miss, got $(cat "$WORKDIR/case2.out")"
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
  if ! echo "$out" | grep -q "OP_PREFLIGHT_REVIEWER_PAT=rev-pat-5"; then
    fail "test_status_alias: stdout missing reviewer PAT export"
    return
  fi
  pass "test_status_alias: --status behaves like --check"
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
# test_check_deploy_no_python3_probe (nathanpayne-codex Phase 4b r1 on
# PR #292): --check --mode deploy must NOT invoke python3 to validate
# ADC. Probe by PATH-shimming python3 with an aborting stub and
# verifying the --check path exits 0 with cached exports rather than
# aborting via the stub.
# ---------------------------------------------------------------------------
test_check_deploy_no_python3_probe() {
  local cache_dir="$WORKDIR/deploy-no-python3-cache"
  mkdir -p "$cache_dir" && chmod 700 "$cache_dir"
  local adc_file="$WORKDIR/deploy-no-python3-adc.json"
  # Fake but well-formed service_account JSON. adc_is_usable
  # short-circuits to OK on service_account creds without HTTP, but
  # if --check honors the contract it shouldn't even reach
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
echo "FATAL: --check --mode deploy invoked python3 with args: $*" >&2
exit 97
EOF
  chmod +x "$py_stub/python3"

  local out rc=0
  out=$(OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
        PATH="$py_stub:$STUB_DIR:$PATH" \
        "$SCRIPT" --agent claude --mode deploy --check 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_check_deploy_no_python3_probe: --check --mode deploy returned rc=$rc; out=$out"
    return
  fi
  if echo "$out" | grep -q "invoked python3"; then
    fail "test_check_deploy_no_python3_probe: --check --mode deploy invoked python3 (ADC probe leaked)"
    return
  fi
  if ! echo "$out" | grep -q "export GOOGLE_APPLICATION_CREDENTIALS="; then
    fail "test_check_deploy_no_python3_probe: --check --mode deploy did not emit ADC export; out=$out"
    return
  fi
  pass "test_check_deploy_no_python3_probe: --check --mode deploy emits ADC without python3 probe"
}

# ---------------------------------------------------------------------------
# test_check_deploy_firebase_sa_no_python3_probe: --check must stay a
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

  if [ "$rc" -ne 0 ]; then
    fail "test_check_deploy_firebase_sa_no_python3_probe: --check returned rc=$rc; out=$out"
    return
  fi
  if echo "$out" | grep -q "invoked python3"; then
    fail "test_check_deploy_firebase_sa_no_python3_probe: --check invoked python3; out=$out"
    return
  fi
  if ! echo "$out" | grep -q "export OP_PREFLIGHT_FIREBASE_SA_TMPFILE="; then
    fail "test_check_deploy_firebase_sa_no_python3_probe: missing Firebase SA marker export; out=$out"
    return
  fi
  pass "test_check_deploy_firebase_sa_no_python3_probe: --check emits Firebase SA without python3 probe"
}

# ---------------------------------------------------------------------------
# test_check_deploy_firebase_sa_project_mismatch_fails_closed:
# --check is probe-free, but it must still refuse a Firebase SA cache
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
      "$SCRIPT" --mode deploy >"$case_dir/out" 2>"$case_dir/err"
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
  if echo "$out" | grep -q "OP_PREFLIGHT_ADC_TMPFILE"; then
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
  cat > "$cache_dir/op-preflight-.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=''
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$bad_sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$bad_sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$project
EOF
  chmod 600 "$cache_dir/op-preflight-.env"

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
      "$SCRIPT" --mode deploy >"$case_dir/out" 2>"$case_dir/err"
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
  cat > "$cache_dir/op-preflight-.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=''
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$cached_sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$cached_sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$cached_project
EOF
  chmod 600 "$cache_dir/op-preflight-.env"

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
      "$SCRIPT" --mode deploy >"$case_dir/out" 2>"$case_dir/err"
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
  local cached_sa_file="$cache_dir/op-preflight--firebase-sa.json"

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
  cat > "$cache_dir/op-preflight-.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=''
OP_PREFLIGHT_MODE=deploy
OP_PREFLIGHT_DONE=1
GOOGLE_APPLICATION_CREDENTIALS=$cached_sa_file
OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$cached_sa_file
OP_PREFLIGHT_FIREBASE_PROJECT=$current_project
EOF
  chmod 600 "$cache_dir/op-preflight-.env"

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
      "$SCRIPT" --mode deploy >"$case_dir/out" 2>"$case_dir/err"
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

test_check_fresh_cache
test_check_missing_cache
test_check_stale_cache
test_check_mutex
test_status_alias
test_quiet_mode
test_default_mode_is_review
test_check_deploy_no_python3_probe
test_check_deploy_firebase_sa_no_python3_probe
test_check_deploy_firebase_sa_project_mismatch_fails_closed
test_deploy_mode_prefers_firebase_sa_over_gcp_adc
test_deploy_mode_refreshes_unusable_cached_firebase_sa
test_deploy_mode_refreshes_mismatched_cached_firebase_sa
test_deploy_mode_refreshes_cached_firebase_sa_file_mismatch

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
