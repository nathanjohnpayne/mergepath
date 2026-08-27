#!/usr/bin/env bash
# tests/test_resolve_pr_threads_read_failure.sh — #1104
#
# The HEAD-oid read is the FIRST call every disposition sweep makes, so its
# failure behaviour is the sweep's failure behaviour. Before #1104 it discarded
# the error body and exited 2 for every cause, which made a rate-limited
# reviewer PAT indistinguishable from a missing PR. Replies still posted (a
# separate, earlier call), so the loop looked healthy while nothing was ever
# resolved and threads accumulated until the PR could not converge.
#
# What is under test is therefore not "does it fail" but "does it fail
# DISTINGUISHABLY": a caller must be able to tell "I looked and there was
# nothing to do" from "I never managed to look".

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-pr-threads.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rpt-readfail.XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub `gh` so every call fails with the given stderr, which is what a
# rate-limited / missing / transient call looks like to this script.
# Portable bounded execution. `timeout` is GNU coreutils and is NOT present on
# a stock macOS box, where it would return 127 for every invocation below and
# fail this suite without running the resolver once. Same fallback shape as
# p4b_run_with_timeout in scripts/phase-4b/lib.sh: perl's alarm survives exec,
# so the target stays bounded.
bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"
  else
    # No bound available: run unbounded rather than reporting a false failure.
    # A hang here is visible as a stuck suite, which is honest; a 127 is not.
    echo "NOTE: neither timeout nor perl available; running unbounded" >&2
    "$@"
  fi
}

run_with_stub() {
  local stderr_line="$1"; shift
  printf '#!/usr/bin/env bash\necho %q >&2\nexit 1\n' "$stderr_line" > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"
  ( cd "$ROOT" \
    && PATH="$STUB_DIR:$PATH" \
       GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=2 \
       OP_PREFLIGHT_REVIEWER_PAT=stub-token \
       bounded 60 bash "$SCRIPT" 999 --repo owner/name --list ) >"$STUB_DIR/out" 2>&1
  echo $?
}

# --- rate limit: must be exit 4, must name the account -----------------------
rc=$(run_with_stub "gh: API rate limit exceeded for user ID 270731004. (HTTP 403)")
out="$(cat "$STUB_DIR/out")"
[ "$rc" = "4" ] && ok "rate-limited read exits 4 (could-not-look), not 2" \
                || bad "rate-limited read exited $rc, expected 4"
grep -qi "RATE LIMITED" <<<"$out" && ok "rate-limit failure says so in plain words" \
                                  || bad "rate-limit failure does not name the cause: $out"
grep -q "270731004" <<<"$out" && ok "rate-limit failure names the exhausted user ID" \
                              || bad "rate-limit failure does not name the user ID"
grep -qi "nothing was resolved" <<<"$out" \
  && ok "rate-limit failure states no work was done (not a completed pass)" \
  || bad "rate-limit failure does not distinguish itself from a completed sweep"
# The /rate_limit endpoint is exempt and reports a fresh window while real calls
# 403, so steering the operator to it would actively mislead. Guard the steer.
grep -qi "do not trust gh api rate_limit" <<<"$out" \
  && ok "rate-limit failure warns that gh api rate_limit is exempt and misleading" \
  || bad "rate-limit failure omits the /rate_limit caveat"

# --- genuine 404: still exit 2, and must NOT claim a rate limit ---------------
rc=$(run_with_stub "gh: Not Found (HTTP 404)")
out="$(cat "$STUB_DIR/out")"
[ "$rc" = "2" ] && ok "missing PR exits 2 (we looked; it is not there)" \
                || bad "missing PR exited $rc, expected 2"
grep -qi "RATE LIMITED" <<<"$out" && bad "404 wrongly reported as a rate limit" \
                                  || ok "404 is not misreported as a rate limit"

# --- unclassified transient: exit 4, never silently 0 ------------------------
rc=$(run_with_stub "gh: connection reset by peer")
[ "$rc" = "4" ] && ok "unclassified read failure exits 4 rather than passing silently" \
                || bad "unclassified read failure exited $rc, expected 4"

# --- the error body must reach the operator at all ---------------------------
out="$(cat "$STUB_DIR/out")"
grep -q "gh said:" <<<"$out" && ok "the underlying gh error body is surfaced, not discarded" \
                             || bad "gh error body was discarded (the #1104 root cause)"

# --- the error body on STDOUT, with the retry helper ABSENT ------------------
# `gh api` writes its HTTP error body to STDOUT, not stderr. The degraded path
# (no gh-retry-helpers.sh) previously sent stdout into HEAD_OID and classified
# only stderr, so the one text that distinguishes a 403 rate limit from a 404
# was thrown away -- the exact discard this suite exists to prevent, one path
# over. A unique marker is used so a pass cannot come from some other message.
STDOUT_MARKER="UNIQUEBODY7f3a rate limit exceeded for user ID 270731004"
NOHELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rpt-nohelper.XXXXXX")"
mkdir -p "$NOHELPER_DIR/scripts/lib" "$NOHELPER_DIR/.github"
cp "$ROOT/scripts/resolve-pr-threads.sh" "$NOHELPER_DIR/scripts/"
for dep in preflight-helpers.sh gh-token-resolver.sh; do
  [ -f "$ROOT/scripts/lib/$dep" ] && cp "$ROOT/scripts/lib/$dep" "$NOHELPER_DIR/scripts/lib/"
done
# gh-retry-helpers.sh deliberately NOT copied: this is the degraded path.
[ -f "$ROOT/.github/review-policy.yml" ] && cp "$ROOT/.github/review-policy.yml" "$NOHELPER_DIR/.github/"

# stderr stays EMPTY; the body goes to stdout, which is what gh actually does.
printf '#!/usr/bin/env bash\necho %q\nexit 1\n' "$STDOUT_MARKER" > "$STUB_DIR/gh"
chmod +x "$STUB_DIR/gh"
( cd "$NOHELPER_DIR" \
  && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_REVIEWER_PAT=stub-token \
     bounded 60 bash scripts/resolve-pr-threads.sh 999 --repo owner/name --list ) \
  >"$STUB_DIR/nohelper.out" 2>&1
nh_rc=$?
nh_out="$(cat "$STUB_DIR/nohelper.out")"
rm -rf "$NOHELPER_DIR"

[ "$nh_rc" = "4" ] \
  && ok "stdout-only error body, retry helper absent: still exits 4" \
  || bad "stdout-only error body: exited $nh_rc, expected 4"
grep -q "UNIQUEBODY7f3a" <<<"$nh_out" \
  && ok "the stdout error body reaches the operator (not discarded into HEAD_OID)" \
  || bad "the stdout error body was discarded; output: $nh_out"
grep -qi "RATE LIMITED" <<<"$nh_out" \
  && ok "a stdout-only rate-limit body is still CLASSIFIED as a rate limit" \
  || bad "stdout-only rate-limit body was not classified: $nh_out"

echo
echo "test_resolve_pr_threads_read_failure: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
