#!/usr/bin/env bash
# tests/test_backfill_unresolved_feedback.sh
#
# Unit tests for scripts/sweep-unresolved-feedback/backfill.sh (#566): the
# one-time driver that runs resolve-pr-threads.sh --resolve-actioned over the
# closed PRs enumerate.sh reports as still carrying unresolved bot threads.
#
# Strategy: copy backfill.sh into a fixture tree alongside STUB enumerate.sh
# and resolve-pr-threads.sh, so the driver exercises its real arg-parsing,
# per-PR loop, summary aggregation, and exit codes without any network.
#
# Bash 3.2 compatible.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/sweep-unresolved-feedback/backfill.sh"
[ -x "$SRC" ] || { echo "missing or non-executable: $SRC" >&2; exit 1; }

pass=0; fail=0
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/backfill-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

# Fixture tree: backfill.sh resolves enumerate.sh from its own dir and
# resolve-pr-threads.sh from <root>/scripts, so mirror that layout.
FR="$SCRATCH/repo"
mkdir -p "$FR/scripts/sweep-unresolved-feedback"
cp "$SRC" "$FR/scripts/sweep-unresolved-feedback/backfill.sh"
chmod +x "$FR/scripts/sweep-unresolved-feedback/backfill.sh"

# Stub enumerate.sh: emit NDJSON for 2 distinct PRs (with one duplicate line
# to prove de-duplication) to $SWEEP_OUTPUT.
cat > "$FR/scripts/sweep-unresolved-feedback/enumerate.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out="${SWEEP_OUTPUT:-/dev/stdout}"
case "$out" in /dev/stdout|-) : ;; *) : > "$out" ;; esac
{
  printf '%s\n' '{"repo":"owner/alpha","pr_number":11,"thread_id":"T1"}'
  printf '%s\n' '{"repo":"owner/alpha","pr_number":11,"thread_id":"T2"}'
  printf '%s\n' '{"repo":"owner/alpha","pr_number":22,"thread_id":"T3"}'
} >> "$out"
STUB
chmod +x "$FR/scripts/sweep-unresolved-feedback/enumerate.sh"

# Stub resolve-pr-threads.sh: log argv, then print a summary line in the real
# format. Behavior is selected by $STUB_RESOLVE_MODE so each test can drive
# the dry-run / execute / failure shapes.
cat > "$FR/scripts/resolve-pr-threads.sh" <<'STUB'
#!/usr/bin/env bash
echo "RESOLVE_ARGV: $*" >> "$STUB_RESOLVE_LOG"
dry=0
for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
case "${STUB_RESOLVE_MODE:-ok}" in
  fail)
    echo "Resolved: 0  Skipped (human): 0  Skipped (stale-HEAD): 0  Skipped (not-actioned): 0  Failed: 1  Readback-failed: 0"
    exit 2 ;;
  *)
    if [ "$dry" -eq 1 ]; then
      echo "(dry-run; no threads modified) — would-resolve: 1, skipped (human): 0, skipped (stale-HEAD): 0, skipped (not-actioned): 1"
      exit 3
    else
      echo "Resolved: 1  Skipped (human): 0  Skipped (stale-HEAD): 0  Skipped (not-actioned): 1  Failed: 0  Readback-failed: 0"
      exit 3
    fi ;;
esac
STUB
chmod +x "$FR/scripts/resolve-pr-threads.sh"

BF="$FR/scripts/sweep-unresolved-feedback/backfill.sh"

run_bf() { # mode, extra-args... → sets OUT/RC, fresh resolve log
  STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"
  export STUB_RESOLVE_LOG
  set +e
  OUT=$(STUB_RESOLVE_MODE="$1" GH_TOKEN=dummy bash "$BF" "${@:2}" --repo owner/alpha 2>&1)
  RC=$?
  set -e
}

# ── Test 1: dry-run by default — passes --dry-run, aggregates would-resolve,
#    de-dupes to 2 PRs, exit 0.
run_bf ok
if [ "$RC" -eq 0 ] \
   && grep -q 'DRY-RUN' <<<"$OUT" \
   && grep -q 'would-resolve=2' <<<"$OUT" \
   && [ "$(grep -c 'RESOLVE_ARGV:.*--dry-run' "$STUB_RESOLVE_LOG")" -eq 2 ]; then
  pass=$((pass+1)); echo "PASS: dry-run default — 2 PRs, --dry-run passed, would-resolve aggregated"
else
  fail=$((fail+1)); echo "FAIL: dry-run default (rc=$RC)" >&2; echo "$OUT" | sed 's/^/  /' >&2
fi

# ── Test 2: --execute drops --dry-run and aggregates resolved, exit 0.
run_bf ok --execute
if [ "$RC" -eq 0 ] \
   && grep -q 'EXECUTE' <<<"$OUT" \
   && grep -q 'resolved=2' <<<"$OUT" \
   && ! grep -q -- '--dry-run' "$STUB_RESOLVE_LOG" \
   && [ "$(grep -c 'RESOLVE_ARGV:.*--resolve-actioned' "$STUB_RESOLVE_LOG")" -eq 2 ]; then
  pass=$((pass+1)); echo "PASS: --execute — no --dry-run, resolved aggregated"
else
  fail=$((fail+1)); echo "FAIL: --execute (rc=$RC)" >&2; echo "$OUT" | sed 's/^/  /' >&2
fi

# ── Test 3: a resolve/readback failure on any PR → backfill exits 2.
run_bf fail --execute
if [ "$RC" -eq 2 ] && grep -q 'failed=' <<<"$OUT"; then
  pass=$((pass+1)); echo "PASS: resolve failure propagates as exit 2 (fail closed)"
else
  fail=$((fail+1)); echo "FAIL: failure should exit 2 (rc=$RC)" >&2; echo "$OUT" | sed 's/^/  /' >&2
fi

# ── Test 4: resolve-actioned is the mode passed (never --auto-resolve-bots).
run_bf ok
if ! grep -q -- '--auto-resolve-bots' "$STUB_RESOLVE_LOG"; then
  pass=$((pass+1)); echo "PASS: never invokes the blunt --auto-resolve-bots mode"
else
  fail=$((fail+1)); echo "FAIL: backfill used --auto-resolve-bots" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_backfill_unresolved_feedback: PASS ($pass tests)"; exit 0
else
  echo "test_backfill_unresolved_feedback: FAIL ($fail of $((pass+fail)))" >&2; exit 1
fi
