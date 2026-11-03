#!/usr/bin/env bash
# tests/test_op_preflight_pr_assets.sh
#
# Unit tests for `scripts/op-preflight.sh --mode pr-assets` (mergepath#2938):
# the author credential scoped to nathanjohnpayne/pr-assets, cached in its own
# slot and emitted alone.
#
# PATH-shims `op` (answers exactly one reference, logs every call), `ssh` and
# `gh` (both fatal: this mode never warms SSH or reads the gh keyring). The
# cache lives in a scratch OP_PREFLIGHT_CACHE_DIR. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/op-preflight.sh"
[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/op-preflight-pr-assets-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The reference the SCRIPT maps the pr-assets credential to, read from the
# script rather than restated, so a remap moves the fixture with it.
ITEM="$(sed -n 's/^PR_ASSETS_PAT_ITEM="\([a-z0-9]\{26\}\)"$/\1/p' "$SCRIPT" | head -1)"
[ -n "$ITEM" ] || { echo "FIXTURE ERROR: cannot read PR_ASSETS_PAT_ITEM from $SCRIPT" >&2; exit 1; }
REF="op://Private/$ITEM/credential"
[ "$ITEM" = "5yaa7l2s7lrxp2vl6cem43ksre" ] || fail "pr-assets item is not the owner-provisioned 5yaa7l2s7lrxp2vl6cem43ksre"

TOKEN="github_pat_PRASSETS_TESTONLY_0000000000000000000000000000000000000000000000000000000000"

STUB="$W/bin"
mkdir -p "$STUB"
cat > "$STUB/op" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/op.log"
if [ "\${OP_STUB_FAIL:-0}" = 1 ]; then echo "[ERROR] vault locked" >&2; exit 1; fi
if [ "\$1" = read ] && [ "\$2" = "$REF" ]; then printf '%s\n' "\${OP_STUB_TOKEN-$TOKEN}"; exit 0; fi
echo "FATAL: unexpected op call: \$*" >&2
exit 99
EOF
cat > "$STUB/ssh" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: pr-assets mode invoked ssh: $*" >&2
exit 98
EOF
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: pr-assets mode invoked gh: $*" >&2
exit 97
EOF
chmod +x "$STUB/op" "$STUB/ssh" "$STUB/gh"

CACHE="$W/cache"
SLOT="$CACHE/op-preflight-claude-pr-assets.slot"
SESSION="$CACHE/op-preflight-claude.env"

unset OP_SERVICE_ACCOUNT_TOKEN OP_PREFLIGHT_PR_ASSETS_PAT OP_PREFLIGHT_TTL_SECONDS OP_PREFLIGHT_REVIEWER_PAT_REF || true

# run [args...]: sets RC, OUT, ERR.
run() {
  set +e
  PATH="$STUB:$PATH" OP_PREFLIGHT_CACHE_DIR="$CACHE" HOME="$W/home" TMPDIR="$W" \
    "$SCRIPT" "$@" >"$W/out" 2>"$W/err"
  RC=$?
  set -e
  OUT="$(cat "$W/out")"
  ERR="$(cat "$W/err")"
}

# eval_out: evaluate OUT in a clean subshell; print the resulting token (or
# FAILED when the evaluation fails).
eval_out() {
  # The failure guards end in `return 1 2>/dev/null || exit 1`, which exits
  # the capturing subshell: a non-zero subshell status is the failed eval.
  local r
  if r="$( unset OP_PREFLIGHT_PR_ASSETS_PAT; eval "$OUT" >/dev/null 2>&1 || exit 1; printf '%s' "${OP_PREFLIGHT_PR_ASSETS_PAT:-<unset>}" )"; then
    printf '%s' "$r"
  else
    printf 'FAILED'
  fi
}

op_calls() { [ -f "$W/op.log" ] && grep -c . "$W/op.log" || echo 0; }

reset() { rm -rf "$CACHE" "$W/op.log"; mkdir -p "$W/home"; }

test_requires_agent() {
  reset
  run --mode pr-assets
  [ "$RC" -ne 0 ] || { fail "--mode pr-assets without --agent succeeded"; return 0; }
  [ "$(eval_out)" = "FAILED" ] || { fail "--agent error does not fail the eval"; return 0; }
  pass "--mode pr-assets requires --agent"
}

test_fetch_emits_only_the_scoped_token() {
  reset
  run --agent claude --mode pr-assets
  [ "$RC" -eq 0 ] || { fail "fetch: exit $RC: $ERR"; return 0; }
  [ "$(eval_out)" = "$TOKEN" ] || { fail "fetch: eval did not yield the token"; return 0; }
  [ "$(printf '%s\n' "$OUT" | grep -c .)" = "1" ] || { fail "fetch: expected exactly one stdout line: $OUT"; return 0; }
  case "$OUT" in *REVIEWER_PAT*|*AUTHOR_PAT*|*OP_PREFLIGHT_MODE*|*OP_PREFLIGHT_DONE*) fail "fetch: emitted more than the scoped token"; return 0 ;; esac
  [ "$(cat "$W/op.log")" = "read $REF" ] || { fail "fetch: unexpected op calls: $(cat "$W/op.log")"; return 0; }
  [ -f "$SLOT" ] || { fail "fetch: slot not written"; return 0; }
  local mode; mode=$(stat -c '%a' "$SLOT" 2>/dev/null || stat -f '%Lp' "$SLOT")
  [ "$mode" = 600 ] || { fail "fetch: slot mode $mode, want 600"; return 0; }
  [ ! -e "$SESSION" ] || { fail "fetch: wrote the review session file"; return 0; }
  case "$ERR" in *"$TOKEN"*) fail "fetch: token on stderr"; return 0 ;; esac
  pass "--mode pr-assets reads only the credential field of its item and emits only OP_PREFLIGHT_PR_ASSETS_PAT"
}

test_cache_hit_no_op() {
  reset
  run --agent claude --mode pr-assets
  run --agent claude --mode pr-assets
  [ "$RC" -eq 0 ] || { fail "hit: exit $RC"; return 0; }
  [ "$(eval_out)" = "$TOKEN" ] || { fail "hit: wrong token"; return 0; }
  [ "$(op_calls)" = "1" ] || { fail "hit: op called again ($(op_calls) calls)"; return 0; }
  run --agent claude --mode pr-assets --refresh
  [ "$(op_calls)" = "2" ] || { fail "--refresh did not re-read"; return 0; }
  pass "a fresh slot is reused without op; --refresh re-reads"
}

test_check_contract() {
  reset
  run --agent claude --check --mode pr-assets --print-exports
  [ "$RC" -eq 2 ] || { fail "check on empty cache: exit $RC, want 2"; return 0; }
  [ "$(eval_out)" = "FAILED" ] || { fail "check miss does not fail the eval"; return 0; }
  run --agent claude --mode pr-assets
  rm -f "$W/op.log"
  run --agent claude --check --mode pr-assets --print-exports
  [ "$RC" -eq 0 ] || { fail "check hit: exit $RC"; return 0; }
  [ "$(eval_out)" = "$TOKEN" ] || { fail "check --print-exports did not yield the token"; return 0; }
  run --agent claude --check --mode pr-assets
  [ "$RC" -eq 0 ] || { fail "bare check: exit $RC"; return 0; }
  case "$OUT$ERR" in *"$TOKEN"*) fail "bare --check printed the token"; return 0 ;; esac
  [ "$(eval_out)" = "FAILED" ] || { fail "bare --check output evaluates successfully (compat guard missing)"; return 0; }
  [ "$(op_calls)" = "0" ] || { fail "--check invoked op"; return 0; }
  pass "--check never invokes op, prints the token only with --print-exports, and fails the eval on a miss"
}

test_stale_and_remapped_slots_miss() {
  reset
  run --agent claude --mode pr-assets
  sed 's/^OP_PREFLIGHT_PR_ASSETS_CREATED_AT_EPOCH=.*/OP_PREFLIGHT_PR_ASSETS_CREATED_AT_EPOCH=1000/' "$SLOT" > "$W/slot" && cat "$W/slot" > "$SLOT"
  run --agent claude --check --mode pr-assets --print-exports
  [ "$RC" -eq 2 ] || { fail "stale slot passed --check"; return 0; }
  run --agent claude --mode pr-assets
  [ "$(op_calls)" = "2" ] || { fail "stale slot was not re-read"; return 0; }
  sed 's#^OP_PREFLIGHT_PR_ASSETS_PAT_SOURCE_REF=.*#OP_PREFLIGHT_PR_ASSETS_PAT_SOURCE_REF=op://Private/otheritem/credential#' "$SLOT" > "$W/slot" && cat "$W/slot" > "$SLOT"
  run --agent claude --check --mode pr-assets --print-exports
  [ "$RC" -eq 2 ] || { fail "slot from another item passed --check"; return 0; }
  pass "a stale slot or one minted from another 1Password item is a miss"
}

test_op_failure_fails_closed() {
  reset
  run --agent claude --mode pr-assets
  OP_STUB_FAIL=1 run --agent claude --mode pr-assets --refresh
  [ "$RC" -eq 1 ] || { fail "op failure: exit $RC, want 1"; return 0; }
  [ "$(eval_out)" = "FAILED" ] || { fail "op failure: eval succeeded"; return 0; }
  printf '%s\n' "$OUT" | grep -qx 'unset OP_PREFLIGHT_PR_ASSETS_PAT' || { fail "op failure: does not unset an older value"; return 0; }
  [ ! -e "$SLOT" ] || { fail "op failure: old slot kept"; return 0; }
  OP_STUB_TOKEN="" run --agent claude --mode pr-assets
  [ "$RC" -eq 1 ] || { fail "empty credential accepted"; return 0; }
  pass "a failed or empty read fails the eval, unsets the variable and drops the slot"
}

test_review_session_untouched() {
  reset
  mkdir -p "$CACHE"
  printf "OP_PREFLIGHT_CREATED_AT_EPOCH=%s\nOP_PREFLIGHT_REVIEWER_PAT=sentinel-review\nOP_PREFLIGHT_AUTHOR_PAT=sentinel-author\n" "$(date +%s)" > "$SESSION"
  chmod 600 "$SESSION"
  cp "$SESSION" "$W/session.before"
  run --agent claude --mode pr-assets
  run --agent claude --check --mode pr-assets --print-exports
  run --agent claude --mode pr-assets --refresh
  cmp -s "$SESSION" "$W/session.before" || { fail "pr-assets mode modified the review session file"; return 0; }
  case "$OUT" in *sentinel*) fail "pr-assets mode emitted review PATs"; return 0 ;; esac
  pass "pr-assets mode never reads into, rewrites or re-emits the review session file"
}

test_purge() {
  reset
  run --agent claude --mode pr-assets
  run --agent claude --purge
  [ ! -e "$SLOT" ] || { fail "--purge left the pr-assets slot"; return 0; }
  run --agent claude --mode pr-assets
  run --purge-all
  [ ! -e "$SLOT" ] || { fail "--purge-all left the pr-assets slot"; return 0; }
  pass "--purge and --purge-all remove the pr-assets slot"
}

test_service_account_mode_refuses() {
  reset
  OP_SERVICE_ACCOUNT_TOKEN=ops_test run --agent claude --mode pr-assets
  [ "$RC" -ne 0 ] || { fail "service-account mode served pr-assets"; return 0; }
  [ "$(op_calls)" = "0" ] || { fail "service-account refusal still invoked op"; return 0; }
  pass "the service-account lane refuses --mode pr-assets"
}

test_dry_run() {
  reset
  run --agent claude --mode pr-assets --dry-run
  [ "$RC" -eq 0 ] || { fail "dry-run: exit $RC"; return 0; }
  case "$ERR" in *"$ITEM"*"credential"*) ;; *) fail "dry-run does not name the item and field"; return 0 ;; esac
  [ "$(op_calls)" = "0" ] || { fail "dry-run invoked op"; return 0; }
  pass "--dry-run names the item and field without invoking op"
}

test_requires_agent
test_fetch_emits_only_the_scoped_token
test_cache_hit_no_op
test_check_contract
test_stale_and_remapped_slots_miss
test_op_failure_fails_closed
test_review_session_untouched
test_purge
test_service_account_mode_refuses
test_dry_run

echo ""
echo "test_op_preflight_pr_assets: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
