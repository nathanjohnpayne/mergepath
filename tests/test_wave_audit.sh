#!/usr/bin/env bash
# tests/test_wave_audit.sh
#
# Unit tests for scripts/wave-audit.sh (#662): watermark chaining, curated
# scope building, config fail-closed validation, orchestrator dispatch env,
# and the tag-advance rules (APPROVED and empty-scope advance; findings,
# unavailable, and --dry-run never advance).
#
# Strategy: no network, no gh, no real models. A scratch canonical repo (with
# a local bare "origin" for tag pushes) stands in for mergepath via
# WAVE_AUDIT_REPO_DIR; the orchestrator is a fake injected via
# WAVE_AUDIT_ORCHESTRATOR that records argv + P4B_* env + the curated diff.
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WA="$ROOT/scripts/wave-audit.sh"
[ -f "$WA" ] || { echo "missing required path: $WA" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wave-audit-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- scratch canonical repo + bare origin -----------------------------------
CANON="$WORK/canon"
git init -q "$CANON"
git -C "$CANON" config user.email test@example.invalid
git -C "$CANON" config user.name "wave-audit-test"
git -C "$CANON" config commit.gpgsign false
git -C "$CANON" config tag.gpgsign false
mkdir -p "$CANON/scripts" "$CANON/tests" "$CANON/docs"
cat > "$CANON/.mergepath-sync.yml" <<'YAML'
consumers: []
paths:
  - path: scripts/
    type: kit
    consumers: all
  - path: tests/
    type: kit
    consumers: all
  - path: docs/
    type: canonical
    consumers: all
YAML
printf 'a v1\n' > "$CANON/scripts/a.sh"
printf 't v1\n' > "$CANON/tests/t.sh"
printf 'd v1\n' > "$CANON/docs/d.md"
git -C "$CANON" add -A && git -C "$CANON" commit -qm c1
C1="$(git -C "$CANON" rev-parse HEAD)"
printf 'a v2\n' > "$CANON/scripts/a.sh"
printf 'b v1\n' > "$CANON/scripts/b.sh"
printf 't v2\n' > "$CANON/tests/t.sh"
printf 'd v2\n' > "$CANON/docs/d.md"
git -C "$CANON" add -A && git -C "$CANON" commit -qm c2
C2="$(git -C "$CANON" rev-parse HEAD)"
printf 'a v3\n' > "$CANON/scripts/a.sh"
git -C "$CANON" add -A && git -C "$CANON" commit -qm c3
C3="$(git -C "$CANON" rev-parse HEAD)"
printf 't v3\n' > "$CANON/tests/t.sh"
git -C "$CANON" add -A && git -C "$CANON" commit -qm c4
C4="$(git -C "$CANON" rev-parse HEAD)"
printf 'a v5\n' > "$CANON/scripts/a.sh"
git -C "$CANON" add -A && git -C "$CANON" commit -qm c5
C5="$(git -C "$CANON" rev-parse HEAD)"

REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
git -C "$CANON" remote add origin "$REMOTE"

remote_has_tag() { git ls-remote --tags "$REMOTE" "refs/tags/wave-audit-pass/$1" | grep -q .; }

# --- fake orchestrator --------------------------------------------------------
CAPTURE="$WORK/capture"
FAKE_ORCH="$WORK/fake-orch.sh"
cat > "$FAKE_ORCH" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${CAPTURE:?}"
printf '%s\n' "$@" > "$CAPTURE/args"
env | grep '^P4B_' | sort > "$CAPTURE/env" || true
prev=""
for a in "$@"; do
  [ "$prev" = "--diff-file" ] && cp "$a" "$CAPTURE/diff"
  prev="$a"
done
exit "${FAKE_ORCH_EXIT:-0}"
FAKE
chmod +x "$FAKE_ORCH"

# --- policy fixtures -----------------------------------------------------------
POLICY_GOOD="$WORK/policy-good.yml"
cat > "$POLICY_GOOD" <<'YAML'
author_identity: nathanjohnpayne
propagation_audit:
  effort: high
  timeout_seconds: 900
  diff_max_bytes: 800000
  scope_exclude_prefixes:
    - tests/
    - docs/
YAML
POLICY_NOBLOCK="$WORK/policy-noblock.yml"
printf 'author_identity: nathanjohnpayne\n' > "$POLICY_NOBLOCK"
POLICY_BAD="$WORK/policy-bad.yml"
cat > "$POLICY_BAD" <<'YAML'
propagation_audit:
  effort: turbo
YAML

run_wa() { # run_wa <policy> <capture-reset> <args...>; FAKE_ORCH_EXIT via env
  local policy="$1" reset="$2"; shift 2
  [ "$reset" = keep ] || { rm -rf "$CAPTURE"; mkdir -p "$CAPTURE"; }
  WAVE_AUDIT_REPO_DIR="$CANON" \
  WAVE_AUDIT_MANIFEST="$CANON/.mergepath-sync.yml" \
  WAVE_AUDIT_ORCHESTRATOR="$FAKE_ORCH" \
  MERGEPATH_REVIEW_POLICY_PATH="$policy" \
  CAPTURE="$CAPTURE" \
    bash "$WA" "$@"
}

# ===========================================================================
echo "wave-audit.sh — title parsing"
# ===========================================================================
got="$(bash "$WA" --parse-title-only "sync: bulk reconcile to mergepath@75eae1c (ready)")" \
  && [ "$got" = "75eae1c" ] && pass "title with suffix parses to sha" \
  || fail "title with suffix (got '${got:-}')"
if bash "$WA" --parse-title-only "sync: no sha named here" >/dev/null 2>&1; then
  fail "sha-less title accepted"
else pass "sha-less title rejected"; fi

# ===========================================================================
echo "wave-audit.sh — first run (--base), scope, dispatch env, watermark"
# ===========================================================================
out="$(run_wa "$POLICY_GOOD" reset 41 --repo owner/consumer --base "$C1" --head-sha "$C2")" \
  && pass "first run (base=c1 head=c2) exits 0" || fail "first run exited nonzero"
printf '%s' "$out" | jq -e '.orchestrator_exit == 0 and .watermark_advanced == true' >/dev/null \
  && pass "summary JSON reports exit 0 + watermark advanced" \
  || fail "summary JSON wrong: $out"
grep -q -- "--diff-file" "$CAPTURE/args" && pass "orchestrator got --diff-file" || fail "no --diff-file in args"
grep -q "^P4B_CODEX_EFFORT=high$" "$CAPTURE/env" && pass "effort=high exported" || fail "effort env missing"
grep -q "^P4B_ADAPTER_TIMEOUT_SECONDS=900$" "$CAPTURE/env" && pass "timeout=900 exported" || fail "timeout env missing"
grep -q "^P4B_DIFF_MAX_BYTES=800000$" "$CAPTURE/env" && pass "diff budget exported" || fail "diff budget env missing"
grep -q "scripts/b.sh" "$CAPTURE/diff" && pass "curated diff includes in-scope scripts/" || fail "scripts/ change missing from diff"
if grep -q "tests/t.sh" "$CAPTURE/diff" || grep -q "docs/d.md" "$CAPTURE/diff"; then
  fail "curated diff leaked excluded prefixes"
else pass "curated diff excludes tests/ and docs/"; fi
remote_has_tag "$C2" && pass "watermark tag for c2 pushed to origin" || fail "watermark tag for c2 missing on origin"

# ===========================================================================
echo "wave-audit.sh — watermark chaining + config defaults (no block)"
# ===========================================================================
run_wa "$POLICY_NOBLOCK" reset 42 --repo owner/consumer --head-sha "$C3" >/dev/null \
  && pass "second run resolves base from the c2 watermark" || fail "second run exited nonzero"
grep -q "a v3" "$CAPTURE/diff" && pass "chained diff covers c2..c3" || fail "chained diff missing c3 change"
if grep -q "scripts/b.sh" "$CAPTURE/diff"; then
  fail "chained diff re-covers pre-watermark content"
else pass "chained diff excludes already-audited c1..c2 content"; fi
grep -q "^P4B_CODEX_EFFORT=high$" "$CAPTURE/env" && pass "absent block falls back to effort=high" || fail "default effort wrong"
remote_has_tag "$C3" && pass "watermark advanced to c3" || fail "watermark tag for c3 missing"

# ===========================================================================
echo "wave-audit.sh — empty in-scope range advances vacuously"
# ===========================================================================
out="$(run_wa "$POLICY_GOOD" reset 43 --repo owner/consumer --head-sha "$C4")" \
  && pass "tests-only range (c3..c4) exits 0" || fail "empty-scope run exited nonzero"
[ ! -e "$CAPTURE/args" ] && pass "orchestrator NOT dispatched on empty scope" || fail "orchestrator was dispatched"
printf '%s' "$out" | jq -e '.skipped == "empty-scope" and .watermark_advanced == true' >/dev/null \
  && pass "summary JSON reports empty-scope + advance" || fail "summary JSON wrong: $out"
remote_has_tag "$C4" && pass "watermark advanced past excluded-only range" || fail "watermark tag for c4 missing"

# ===========================================================================
echo "wave-audit.sh — verdict/tag rules on c4..c5"
# ===========================================================================
FAKE_ORCH_EXIT=1 run_wa "$POLICY_GOOD" reset 44 --repo owner/consumer --head-sha "$C5" >/dev/null 2>&1 \
  && fail "CHANGES_REQUESTED should exit 1" || { [ $? -eq 1 ] && pass "CHANGES_REQUESTED passes exit 1 through" || fail "wrong exit for CHANGES_REQUESTED"; }
remote_has_tag "$C5" && fail "findings advanced the watermark" || pass "no watermark on CHANGES_REQUESTED"

FAKE_ORCH_EXIT=4 run_wa "$POLICY_GOOD" reset 44 --repo owner/consumer --head-sha "$C5" >/dev/null 2>&1 \
  && fail "unavailable should exit 4" || { [ $? -eq 4 ] && pass "adapter-unavailable passes exit 4 through" || fail "wrong exit for unavailable"; }
remote_has_tag "$C5" && fail "unavailable advanced the watermark" || pass "no watermark when reviewer unavailable (range chains forward)"

run_wa "$POLICY_GOOD" reset 44 --repo owner/consumer --head-sha "$C5" --dry-run >/dev/null \
  && pass "dry-run APPROVED exits 0" || fail "dry-run exited nonzero"
grep -q -- "--dry-run" "$CAPTURE/args" && pass "dry-run forwarded to orchestrator" || fail "--dry-run not forwarded"
remote_has_tag "$C5" && fail "dry-run advanced the watermark" || pass "dry-run never advances the watermark"

run_wa "$POLICY_GOOD" reset 44 --repo owner/consumer --head-sha "$C5" >/dev/null \
  && pass "real APPROVED run exits 0" || fail "approved run exited nonzero"
remote_has_tag "$C5" && pass "watermark advanced on APPROVED" || fail "watermark tag for c5 missing"

# ===========================================================================
echo "wave-audit.sh — fail-closed config + missing watermark"
# ===========================================================================
run_wa "$POLICY_BAD" reset 45 --repo owner/consumer --head-sha "$C5" >/dev/null 2>&1 \
  && fail "invalid effort accepted" || { [ $? -eq 3 ] && pass "invalid effort fails closed (exit 3)" || fail "wrong exit for invalid effort"; }
[ ! -e "$CAPTURE/args" ] && pass "orchestrator NOT dispatched on invalid config" || fail "orchestrator dispatched despite invalid config"

for t in $(git -C "$CANON" tag -l 'wave-audit-pass/*'); do git -C "$CANON" tag -d "$t" >/dev/null; done
run_wa "$POLICY_GOOD" reset 46 --repo owner/consumer --head-sha "$C2" >/dev/null 2>&1 \
  && fail "run without watermark or --base accepted" || { [ $? -eq 3 ] && pass "no watermark + no --base fails closed (exit 3)" || fail "wrong exit for missing base"; }

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
