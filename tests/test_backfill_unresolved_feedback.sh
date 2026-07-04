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
if [ "${STUB_ENUM_MODE:-ok}" = "skip" ]; then
  # Mimic enumerate.sh's tolerant skip of an unlistable repo: WARN + no findings.
  echo "enumerate: WARN gh pr list failed for owner/alpha (skipping)" >&2
  exit 0
fi
if [ "${STUB_ENUM_MODE:-ok}" = "empty" ]; then
  # Real empty-SUCCESS case: gh pr list returned an empty list (exit 0, no WARN)
  # — a valid repo with zero closed PRs, OR an unresolvable repo gh silently
  # treats as empty. enumerate emits NO findings and exits 0. This is the case
  # the WARN grep cannot catch; the gh-repo-view pre-validation must.
  exit 0
fi
if [ "${STUB_ENUM_MODE:-ok}" = "skip_pr" ]; then
  # Mimic enumerate.sh skipping ONE PR's thread fetch: emit findings for the PRs
  # it could read PLUS a per-PR GraphQL WARN — a partial (non-empty) drain that
  # must still fail closed.
  echo "enumerate: WARN GraphQL threads query failed for owner/alpha#22 (skipping)" >&2
  printf '%s\n' '{"repo":"owner/alpha","pr_number":11,"thread_id":"T1"}' >> "$out"
  exit 0
fi
if [ "${STUB_ENUM_MODE:-ok}" = "skip_100" ]; then
  # Mimic enumerate.sh examining only page 1 of a PR with >100 review threads:
  # emit findings PLUS the >100-threads truncation WARN — a partial (non-empty)
  # drain that must still fail closed (Codex Phase-4b r3 on #571).
  echo "enumerate: WARN owner/alpha#11 has >100 review threads; sweep examined first page only" >&2
  printf '%s\n' '{"repo":"owner/alpha","pr_number":11,"thread_id":"T1"}' >> "$out"
  exit 0
fi
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
  die)
    # Non-zero exit with NO parseable summary line (a crash before the
    # resolver could print its counters). The backfill must still fail
    # closed on the exit code alone.
    echo "resolve: boom (no parseable summary)" >&2
    exit 2 ;;
  skip_only)
    # A PR that verifies NOTHING but leaves skips behind (drifted / unverified).
    # would-resolve/resolved is 0; skipped is non-zero. Proves skipped-only PRs
    # are still printed per-PR (Codex P3 on #666).
    if [ "$dry" -eq 1 ]; then
      echo "(dry-run; no threads modified) — would-resolve: 0, skipped (human): 0, skipped (stale-HEAD): 0, skipped (not-actioned): 0, skipped (drift): 2"
      exit 3
    else
      echo "Resolved: 0  Skipped (human): 0  Skipped (stale-HEAD): 0  Skipped (not-actioned): 0  Skipped (drift): 2  Failed: 0  Readback-failed: 0"
      exit 3
    fi ;;
  *)
    if [ "$dry" -eq 1 ]; then
      # Emit a non-not-actioned skip category (drift) too, so the backfill's
      # sum-all-skips parse is exercised (would read 0 if it only parsed
      # not-actioned). Per-PR skipped = 0+0+1+2 = 3.
      echo "(dry-run; no threads modified) — would-resolve: 1, skipped (human): 0, skipped (stale-HEAD): 0, skipped (not-actioned): 1, skipped (drift): 2"
      exit 3
    else
      echo "Resolved: 1  Skipped (human): 0  Skipped (stale-HEAD): 0  Skipped (not-actioned): 1  Skipped (drift): 2  Failed: 0  Readback-failed: 0"
      exit 3
    fi ;;
esac
STUB
chmod +x "$FR/scripts/resolve-pr-threads.sh"

# Hermetic `gh` shim: backfill.sh runs `command -v gh` as a dependency check
# (and never calls gh in the fixture — enumerate.sh + resolve-pr-threads.sh are
# stubbed). Provide a no-op gh on PATH so the suite runs on minimal hosts with
# no GitHub CLI installed (Codex Phase-4b on #571). jq stays real (the driver
# parses findings with it), so it is left on the inherited PATH.
mkdir -p "$FR/bin"
cat > "$FR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# No-op gh shim. backfill.sh validates each target with `gh repo view`; force
# that to fail via STUB_GH_REPO_VIEW_FAIL=1 to simulate a nonexistent /
# unauthorized repo — the real empty-success `gh pr list` case that enumerate
# cannot distinguish. All other gh calls are no-ops (enumerate + resolve are
# stubbed, and the dependency check only does `command -v gh`).
# Record every gh invocation when STUB_GH_LOG is set, so a test can assert which
# API the trusted-ref guard queries (the canonical commits API, not local git).
[ -n "${STUB_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_GH_LOG"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ] && [ "${STUB_GH_REPO_VIEW_FAIL:-0}" = "1" ]; then
  exit 1
fi
exit 0
STUB
chmod +x "$FR/bin/gh"
SHIM_PATH="$FR/bin:$PATH"

BF="$FR/scripts/sweep-unresolved-feedback/backfill.sh"

run_bf() { # mode, extra-args... → sets OUT/RC, fresh resolve log
  STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"
  export STUB_RESOLVE_LOG
  set +e
  # MERGEPATH_BACKFILL_TRUSTED_REF_OK=1: the fixture tree is not a git checkout,
  # so the verified-propagation trusted-ref guard would fail closed; the guard
  # itself is exercised separately (see the dedicated test below).
  OUT=$(PATH="$SHIM_PATH" STUB_RESOLVE_MODE="$1" GH_TOKEN=dummy MERGEPATH_BACKFILL_TRUSTED_REF_OK=1 bash "$BF" "${@:2}" --repo owner/alpha 2>&1)
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
  fail=$((fail+1)); echo "FAIL: dry-run default (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
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
  fail=$((fail+1)); echo "FAIL: --execute (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 3: a resolve/readback failure on any PR → backfill exits 2.
run_bf fail --execute
if [ "$RC" -eq 2 ] && grep -q 'failed=' <<<"$OUT"; then
  pass=$((pass+1)); echo "PASS: resolve failure propagates as exit 2 (fail closed)"
else
  fail=$((fail+1)); echo "FAIL: failure should exit 2 (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 4: resolve-actioned is the mode passed (never --auto-resolve-bots).
run_bf ok
if ! grep -q -- '--auto-resolve-bots' "$STUB_RESOLVE_LOG"; then
  pass=$((pass+1)); echo "PASS: never invokes the blunt --auto-resolve-bots mode"
else
  fail=$((fail+1)); echo "FAIL: backfill used --auto-resolve-bots" >&2
fi

# ── Test 5: resolver dies non-zero with NO parseable summary → the backfill
#    still fails closed (exit 2) via the exit-code backstop, not just the
#    parsed Failed:/Readback-failed: counters.
run_bf die --execute
if [ "$RC" -eq 2 ] && grep -q 'failed=' <<<"$OUT"; then
  pass=$((pass+1)); echo "PASS: summary-less resolver death fails closed (exit-code backstop)"
else
  fail=$((fail+1)); echo "FAIL: die mode should exit 2 (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 6: a non-numeric BACKFILL_MAX_PRS is rejected up front (exit 1),
#    not left to crash `[ "$MAX" -gt 0 ]` under set -e mid-loop.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_RESOLVE_MODE=ok GH_TOKEN=dummy BACKFILL_MAX_PRS=foo bash "$BF" --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -qi 'BACKFILL_MAX_PRS must be' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: non-numeric BACKFILL_MAX_PRS rejected up front (exit 1, no resolver call)"
else
  fail=$((fail+1)); echo "FAIL: bad BACKFILL_MAX_PRS should exit 1 with no resolver call (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 7: enumerate skips an unlistable target (WARN, no findings) → the
#    backfill fails closed instead of reporting a successful empty drain, and
#    never calls the resolver (Codex Phase-4b on #571).
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_ENUM_MODE=skip STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --execute --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qi 'failing closed' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: enumerate skip (unlistable repo) fails closed, no resolver call"
else
  fail=$((fail+1)); echo "FAIL: enumerate skip should fail closed (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 8: an unresolvable --repo target (gh repo view fails) fails closed
#    BEFORE enumerate, even when gh pr list would have returned empty-SUCCESS
#    (the real case Codex flagged: the WARN path does not fire). No resolver call.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_GH_REPO_VIEW_FAIL=1 STUB_ENUM_MODE=empty STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qi 'not resolvable' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: unresolvable --repo (gh repo view fails) fails closed, no resolver call"
else
  fail=$((fail+1)); echo "FAIL: unresolvable --repo should fail closed (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 9: a RESOLVABLE repo with zero findings (gh repo view OK + enumerate
#    empty-success) is a legitimate clean drain → exit 0, NOT a false failure.
#    Proves the fix distinguishes "real repo, 0 findings" from "bad repo".
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_ENUM_MODE=empty STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q 'would-resolve=0' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: resolvable repo with zero findings is a clean empty drain (exit 0)"
else
  fail=$((fail+1)); echo "FAIL: valid empty repo should exit 0 (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 10: enumerate skips ONE PR's thread fetch (per-PR GraphQL WARN) while
#    emitting other findings → backfill still fails closed on the partial drain,
#    before the resolve loop (Codex Phase-4b r2 on #571, P2).
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_ENUM_MODE=skip_pr STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --execute --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qi 'failing closed' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: per-PR thread-fetch skip fails closed before resolving (partial drain)"
else
  fail=$((fail+1)); echo "FAIL: per-PR skip should fail closed (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 11: a PR with >100 review threads (enumerate examines page 1 only +
#    emits the truncation WARN) → backfill fails closed on the partial drain,
#    before the resolve loop (Codex Phase-4b r3 on #571, P2).
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_ENUM_MODE=skip_100 STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --execute --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qi 'failing closed' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: >100-review-threads truncation fails closed before resolving (partial drain)"
else
  fail=$((fail+1)); echo "FAIL: >100-threads truncation should fail closed (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 12: a positional targets FILE whose final entry has NO trailing
#    newline is not silently dropped — backfill normalizes it, validates the
#    entry, and fails closed on the invalid repo instead of a false empty drain
#    (CodeRabbit + Codex Phase-4b r4 on #571: `while read` drops a no-newline
#    last line).
NL_TARGETS="$SCRATCH/no-newline-targets.txt"
printf 'owner/alpha' > "$NL_TARGETS"   # deliberately NO trailing newline
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_GH_REPO_VIEW_FAIL=1 STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" "$NL_TARGETS" 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qi 'not resolvable' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: no-trailing-newline targets file — final entry validated, fails closed (not dropped)"
else
  fail=$((fail+1)); echo "FAIL: no-newline targets final entry should not be dropped (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 13: --mode resolve-verified-propagation delegates the verified mode
#    to the resolver (never --resolve-actioned) — the Track-C drain path.
run_bf ok --mode resolve-verified-propagation
if [ "$RC" -eq 0 ] \
   && [ "$(grep -c 'RESOLVE_ARGV:.*--resolve-verified-propagation' "$STUB_RESOLVE_LOG")" -eq 2 ] \
   && ! grep -q -- '--resolve-actioned' "$STUB_RESOLVE_LOG"; then
  pass=$((pass+1)); echo "PASS: --mode resolve-verified-propagation delegates the verified mode"
else
  fail=$((fail+1)); echo "FAIL: verified-propagation mode not delegated (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 14: an invalid --mode is rejected up front (exit 1), no resolver call.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --mode bogus --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -qi 'mode must be' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: invalid --mode rejected up front (exit 1, no resolver call)"
else
  fail=$((fail+1)); echo "FAIL: invalid --mode should exit 1 (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 15: --mode resolve-verified-propagation SKIPS the canonical repo — on
#    the hub, verified-propagation compares a file to itself (self-match → false
#    "propagation verified"). Override the canonical slug to the fixture repo via
#    MERGEPATH_CANONICAL_REPO; every owner/alpha PR is skipped, no resolver call,
#    clean exit.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" MERGEPATH_CANONICAL_REPO=owner/alpha STUB_RESOLVE_MODE=ok GH_TOKEN=dummy MERGEPATH_BACKFILL_TRUSTED_REF_OK=1 bash "$BF" --mode resolve-verified-propagation --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -qi 'SKIP (verified-propagation N/A' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: verified-propagation skips the canonical repo (no self-match resolve)"
else
  fail=$((fail+1)); echo "FAIL: canonical repo should be skipped in verified mode (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 16: the exclusion is MODE-SCOPED — under the default --resolve-actioned
#    the same canonical repo IS drained (resolver called), proving verified-mode's
#    skip does not leak into the actioned drain.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" MERGEPATH_CANONICAL_REPO=owner/alpha STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && [ "$(grep -c 'RESOLVE_ARGV:.*--resolve-actioned' "$STUB_RESOLVE_LOG")" -eq 2 ] \
   && ! grep -qi 'SKIP (verified-propagation' <<<"$OUT"; then
  pass=$((pass+1)); echo "PASS: canonical-repo exclusion is mode-scoped (actioned drain unaffected)"
else
  fail=$((fail+1)); echo "FAIL: actioned mode should still drain the canonical repo (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 17: the canonical self-match is case-INSENSITIVE (GitHub slugs are).
#    A case-variant MERGEPATH_CANONICAL_REPO still skips owner/alpha; a raw
#    string compare would miss the mismatch and resolve canonical PRs
#    (CodeRabbit Functional Correctness on #666).
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" MERGEPATH_CANONICAL_REPO=Owner/Alpha STUB_RESOLVE_MODE=ok GH_TOKEN=dummy MERGEPATH_BACKFILL_TRUSTED_REF_OK=1 bash "$BF" --mode resolve-verified-propagation --repo owner/alpha 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -qi 'SKIP (verified-propagation N/A' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ]; then
  pass=$((pass+1)); echo "PASS: canonical self-match is case-insensitive (case-variant slug still skips)"
else
  fail=$((fail+1)); echo "FAIL: case-variant canonical slug should still skip (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 18: skip counters SUM all categories, not just not-actioned. The stub
#    reports skipped (not-actioned):1 + skipped (drift):2 = 3 per PR; across the
#    2 PRs the dry-run summary must show skipped=6, so verified-propagation
#    drift / verify-error / no-upstream-evidence skips are not hidden from the
#    operator's scope review (Codex P2 on #666).
run_bf ok
if [ "$RC" -eq 0 ] && grep -q 'skipped=6' <<<"$OUT"; then
  pass=$((pass+1)); echo "PASS: summary sums ALL skip categories (skipped=6, not just not-actioned)"
else
  fail=$((fail+1)); echo "FAIL: skip counters should sum all categories (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 19: verified-propagation drops the canonical repo from the target set
#    BEFORE enumerate, so a canonical-only enumerate WARN cannot fail-close the
#    consumer drain (Codex P2 on #666). The exclusion notice fires in verified
#    mode and NOT in the default actioned mode.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
set +e
OUT=$(PATH="$SHIM_PATH" MERGEPATH_CANONICAL_REPO=owner/alpha STUB_RESOLVE_MODE=ok GH_TOKEN=dummy MERGEPATH_BACKFILL_TRUSTED_REF_OK=1 bash "$BF" --mode resolve-verified-propagation --repo owner/alpha 2>&1)
OUT_ACTIONED=$(PATH="$SHIM_PATH" MERGEPATH_CANONICAL_REPO=owner/alpha STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --repo owner/alpha 2>&1)
set -e
if grep -qi 'excluded canonical repo' <<<"$OUT" && ! grep -qi 'excluded canonical repo' <<<"$OUT_ACTIONED"; then
  pass=$((pass+1)); echo "PASS: verified-propagation filters canonical before enumerate; actioned does not"
else
  fail=$((fail+1)); echo "FAIL: canonical pre-enumerate filter should fire only in verified mode" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

# ── Test 20: the verified-propagation trusted-ref guard fails closed when the
#    checkout cannot be proven to sit at the canonical default-branch tip. The
#    fixture tree is not a git repo, so without MERGEPATH_BACKFILL_TRUSTED_REF_OK
#    the guard refuses to run (exit 1) before any enumerate/resolve (Codex P2 on
#    #666). Actioned mode is exempt (it never reads canonical) — Tests 1-2 run
#    without the override.
STUB_RESOLVE_LOG="$SCRATCH/resolve.log"; : > "$STUB_RESOLVE_LOG"; export STUB_RESOLVE_LOG
STUB_GH_LOG="$SCRATCH/gh.log"; : > "$STUB_GH_LOG"; export STUB_GH_LOG
set +e
OUT=$(PATH="$SHIM_PATH" STUB_RESOLVE_MODE=ok GH_TOKEN=dummy bash "$BF" --mode resolve-verified-propagation --repo owner/beta 2>&1)
RC=$?
set -e
# The guard must read the trusted OID from the CANONICAL repo's commits API
# ($CANONICAL_REPO, default nathanjohnpayne/mergepath), NOT a local origin/
# tracking ref. Assert it hit `api repos/<canonical>/commits/<branch>` (Codex P2
# on #666); an origin-based guard would leave no such call.
if [ "$RC" -eq 1 ] && grep -qi 'non-trusted ref' <<<"$OUT" && [ ! -s "$STUB_RESOLVE_LOG" ] \
   && grep -q 'api repos/.*/commits/' "$STUB_GH_LOG"; then
  pass=$((pass+1)); echo "PASS: verified-propagation fails closed from a non-trusted checkout, via the canonical commits API"
else
  fail=$((fail+1)); echo "FAIL: trusted-ref guard should fail closed via the canonical commits API (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi
unset STUB_GH_LOG

# ── Test 21: a skipped-only PR (0 resolves, non-zero skips) is still printed
#    per-PR, not just folded into the summary total, so the operator sees WHICH
#    PRs carry unverified/drifted threads (Codex P3 on #666).
run_bf skip_only
if [ "$RC" -eq 0 ] && grep -q 'would-resolve=0 skipped=2' <<<"$OUT"; then
  pass=$((pass+1)); echo "PASS: skipped-only PR is printed per-PR (not hidden when would-resolve=0)"
else
  fail=$((fail+1)); echo "FAIL: skipped-only PR should still print per-PR (rc=$RC)" >&2; awk '{print "  " $0}' <<<"$OUT" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_backfill_unresolved_feedback: PASS ($pass tests)"; exit 0
else
  echo "test_backfill_unresolved_feedback: FAIL ($fail of $((pass+fail)))" >&2; exit 1
fi
