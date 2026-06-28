#!/usr/bin/env bash
# tests/test_gh_retry_helpers.sh
#
# Unit tests for scripts/lib/gh-retry-helpers.sh with_gh_retry (#536).
#
# The headline contract this nails down: on the SUCCESS path, stdout must
# be emitted CLEAN — gh's stderr chatter (deprecation notices, warnings)
# must NOT contaminate the captured output, because downstream consumers
# (e.g. codex-review-check.sh) parse that output as JSON / exact text. The
# prior implementation captured `2>&1` and re-emitted the combined stream
# on success, so a single stderr warning corrupted the parse.
#
# Strategy: PATH-shim a fake `gh` that writes a known marker to BOTH
# stdout and stderr, plus an env-controlled exit code and attempt counter
# so the retry/backoff classification can be exercised deterministically.
# GH_RETRY_BACKOFF_SECONDS=0 keeps the suite fast.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/gh-retry-helpers.sh"

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-retry-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# PATH-shim `gh`:
#   - prints $FAKE_GH_STDOUT to stdout (default: a JSON-ish marker)
#   - prints $FAKE_GH_STDERR to stderr (default: a deprecation warning)
#   - exits with the code for the current attempt, read from a per-call
#     counter file ($ATTEMPT_FILE) indexing into $FAKE_GH_RCS (space-sep).
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Emit stdout + stderr markers. Callers always set both env vars; we use a
# plain default (no brace-bearing literal) to avoid parameter-expansion
# brace-matching surprises.
stdout_marker="${FAKE_GH_STDOUT-stdout-default}"
stderr_marker="${FAKE_GH_STDERR-stderr-default}"
printf '%s' "$stdout_marker"
printf '%s' "$stderr_marker" >&2

# Determine this call's exit code from the rc list + attempt counter.
rcs="${FAKE_GH_RCS-0}"
idx=0
if [ -n "${ATTEMPT_FILE:-}" ] && [ -f "$ATTEMPT_FILE" ]; then
  idx=$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)
  [ -n "$idx" ] || idx=0
fi
n=$((idx + 1))
[ -n "${ATTEMPT_FILE:-}" ] && printf '%s' "$n" > "$ATTEMPT_FILE"

# Pick the idx-th rc (0-based); last one repeats if we run past the list.
i=0
chosen=0
for rc in $rcs; do
  chosen=$rc
  if [ "$i" -ge "$idx" ]; then break; fi
  i=$((i + 1))
done
exit "$chosen"
STUB
chmod +x "$STUB_DIR/gh"

run_with_retry() {  # env passthrough; args are the gh invocation
  (
    PATH="$STUB_DIR:$PATH"
    GH_RETRY_BACKOFF_SECONDS=0
    export GH_RETRY_BACKOFF_SECONDS
    # shellcheck disable=SC1090
    . "$LIB"
    with_gh_retry "$@"
  )
}

# ---------------------------------------------------------------------------
# Test 1 (headline #536): success path emits ONLY stdout — stderr chatter
# must not appear in the captured stdout.
# ---------------------------------------------------------------------------
echo "--- Test 1: success → clean stdout (no stderr contamination)"
ATTEMPT_FILE="$WORKDIR/att1"; : > "$ATTEMPT_FILE"
set +e
OUT=$(FAKE_GH_STDOUT='{"data":42}' \
      FAKE_GH_STDERR='gh: warning: this flag is deprecated' \
      FAKE_GH_RCS='0' \
      ATTEMPT_FILE="$ATTEMPT_FILE" \
      run_with_retry gh api some/endpoint 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = '{"data":42}' ]; then
  pass "success stdout is clean JSON, no stderr leak (got exactly the stdout marker)"
else
  fail "expected clean '{\"data\":42}' rc=0; got rc=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# Test 1b: the stderr the fake gh wrote must still go SOMEWHERE on success?
# No — on success stderr is intentionally dropped. Assert the captured
# stdout does not contain the warning substring even when both streams are
# merged by the caller (2>&1).
# ---------------------------------------------------------------------------
echo "--- Test 1b: success → merged capture still has clean parseable stdout"
ATTEMPT_FILE="$WORKDIR/att1b"; : > "$ATTEMPT_FILE"
set +e
OUT=$(FAKE_GH_STDOUT='{"ok":true}' \
      FAKE_GH_STDERR='DEPRECATION-NOISE-MARKER' \
      FAKE_GH_RCS='0' \
      ATTEMPT_FILE="$ATTEMPT_FILE" \
      run_with_retry gh api some/endpoint 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = '{"ok":true}' ] \
   && ! printf '%s' "$OUT" | grep -q 'DEPRECATION-NOISE-MARKER'; then
  pass "success path drops stderr noise entirely (merged stream is just stdout)"
else
  fail "expected merged output to be just stdout; got rc=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# Test 2: permanent failure (HTTP 404 in stderr) → fail fast, single
# attempt, combined stream surfaced on stderr.
# ---------------------------------------------------------------------------
echo "--- Test 2: permanent HTTP 404 → fail fast (no retry)"
ATTEMPT_FILE="$WORKDIR/att2"; : > "$ATTEMPT_FILE"
set +e
ERR=$(FAKE_GH_STDOUT='' \
      FAKE_GH_STDERR='gh: Not Found (HTTP 404)' \
      FAKE_GH_RCS='1 0 0' \
      ATTEMPT_FILE="$ATTEMPT_FILE" \
      GH_RETRY_ATTEMPTS=3 \
      run_with_retry gh api missing/thing 2>&1 1>/dev/null)
RC=$?
attempts_used=$(cat "$ATTEMPT_FILE")
set -e
if [ "$RC" = 1 ] && [ "$attempts_used" = 1 ] && printf '%s' "$ERR" | grep -q 'HTTP 404'; then
  pass "HTTP 404 classified permanent → 1 attempt, combined stream on stderr"
else
  fail "expected fail-fast (1 attempt) with HTTP 404 on stderr; got rc=$RC attempts=$attempts_used err=[$ERR]"
fi

# ---------------------------------------------------------------------------
# Test 3: transient failure then success. First attempt HTTP 503, second
# attempt succeeds → retried, and the FINAL stdout is clean (no stderr).
# ---------------------------------------------------------------------------
echo "--- Test 3: transient HTTP 503 then success → retried, clean stdout"
ATTEMPT_FILE="$WORKDIR/att3"; : > "$ATTEMPT_FILE"
set +e
OUT=$(FAKE_GH_STDOUT='{"recovered":1}' \
      FAKE_GH_STDERR='gh: Server Error (HTTP 503)' \
      FAKE_GH_RCS='1 0' \
      ATTEMPT_FILE="$ATTEMPT_FILE" \
      GH_RETRY_ATTEMPTS=3 \
      run_with_retry gh api flaky/thing 2>/dev/null)
RC=$?
attempts_used=$(cat "$ATTEMPT_FILE")
set -e
# Note: on the retry the fake gh still writes the 503 stderr, but the
# SUCCESS-path stdout emit excludes it. Assert the captured stdout is
# exactly the success marker.
if [ "$RC" = 0 ] && [ "$attempts_used" = 2 ] && [ "$OUT" = '{"recovered":1}' ]; then
  pass "HTTP 503 retried once, then clean success stdout (2 attempts)"
else
  fail "expected retry→success clean stdout; got rc=$RC attempts=$attempts_used out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# Test 4: all attempts fail transiently → returns last rc, combined stream
# surfaced on stderr.
# ---------------------------------------------------------------------------
echo "--- Test 4: exhausted retries (all HTTP 503) → last rc + stderr"
ATTEMPT_FILE="$WORKDIR/att4"; : > "$ATTEMPT_FILE"
set +e
ERR=$(FAKE_GH_STDOUT='partial-body' \
      FAKE_GH_STDERR='gh: Server Error (HTTP 503)' \
      FAKE_GH_RCS='1 1 1' \
      ATTEMPT_FILE="$ATTEMPT_FILE" \
      GH_RETRY_ATTEMPTS=3 \
      run_with_retry gh api always/503 2>&1 1>/dev/null)
RC=$?
attempts_used=$(cat "$ATTEMPT_FILE")
set -e
if [ "$RC" = 1 ] && [ "$attempts_used" = 3 ] && printf '%s' "$ERR" | grep -q 'HTTP 503'; then
  pass "exhausted retries → 3 attempts, last rc=1, combined stream on stderr"
else
  fail "expected 3 attempts + rc=1 + 503 on stderr; got rc=$RC attempts=$attempts_used err=[$ERR]"
fi

# ---------------------------------------------------------------------------
# Test 6 (#545 4a P2): the cleanup RETURN trap must self-clear, so it does
# not linger and re-fire on an ENCLOSING function's return — where the
# helper-local `err` is out of scope and, under set -u, would abort the
# caller with `err: unbound variable`. with_gh_retry is invoked from inside
# a function (not the test's usual subshell) to exercise exactly that path.
# ---------------------------------------------------------------------------
echo "--- Test 6: cleanup RETURN trap self-clears (no lingering abort in a set -u caller)"
: > "$WORKDIR/att6"
set +e
LINGER_OUT=$(
  set -uo pipefail
  PATH="$STUB_DIR:$PATH"
  export GH_RETRY_BACKOFF_SECONDS=0
  export FAKE_GH_STDOUT=ok FAKE_GH_RCS=0 ATTEMPT_FILE="$WORKDIR/att6"
  . "$LIB"
  caller_fn() { with_gh_retry gh api x >/dev/null 2>&1; }
  caller_fn
  echo SURVIVED
)
LINGER_RC=$?
set -e
if [ "$LINGER_RC" = 0 ] && [ "$LINGER_OUT" = SURVIVED ]; then
  pass "RETURN trap self-clears — enclosing function return does not hit err: unbound variable"
else
  fail "lingering RETURN trap aborted the caller (rc=$LINGER_RC out=[$LINGER_OUT])"
fi

echo
echo "test_gh_retry_helpers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
