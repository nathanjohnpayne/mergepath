#!/usr/bin/env bash
# tests/test_sync_overrides.sh
#
# Unit tests for scripts/sync/validate-overrides.sh and
# scripts/sync/apply-overrides.sh. Builds a synthetic manifest +
# overrides files in a tempdir, exercises each rule + helper.
#
# Requires: yq (mikefarah/yq v4+), bash 4+. Run manually or from
# scripts/ci/check_sync_overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/sync/validate-overrides.sh"
APPLY_LIB="$ROOT/scripts/sync/apply-overrides.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[[ -x "$VALIDATOR" ]] || { echo "missing or non-executable $VALIDATOR" >&2; exit 1; }
[[ -f "$APPLY_LIB" ]] || { echo "missing $APPLY_LIB" >&2; exit 1; }

# Use the explicit `$TMPDIR/<prefix>.XXXXXX` form for cross-platform
# portability — `mktemp -d -t literal-prefix` is BSD-specific and
# behaves differently on GNU/Linux (CodeRabbit ⚠️ Major on PR #228;
# same defense matchline applied to test_sync_to_downstream.sh in #217).
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-overrides-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

# ---------------------------------------------------------------------------
# Synthetic manifest with two canonical paths, one kit, and one templated
# path with two substitution markers (the templated entry exercises the
# substitutions validation; v1 manifest doesn't yet declare templated
# paths but the validator must support them when they land).
# ---------------------------------------------------------------------------
MANIFEST="$WORKDIR/.mergepath-sync.yml"
cat >"$MANIFEST" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
paths:
  - {path: scripts/keep-in-sync.sh,    type: canonical, consumers: all}
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
  - path: examples/AGENTS.md
    source: examples/AGENTS.md
    dest: AGENTS.md
    type: templated
    consumers: all
    substitutions:
      phase_4b_default: complex-changes
      author_identity: nathanjohnpayne
YAML

# ---------------------------------------------------------------------------
# Test 1: absent overrides file → pass (the "no divergences" common case).
# ---------------------------------------------------------------------------
absent_dir="$WORKDIR/absent"
mkdir -p "$absent_dir"
cd "$absent_dir"
if "$VALIDATOR" "$absent_dir/.sync-overrides.yml" "$MANIFEST" >/dev/null 2>&1; then
  pass "absent overrides file → exits 0"
else
  fail "absent overrides file should pass; validator returned non-zero"
fi
cd "$ROOT"

# ---------------------------------------------------------------------------
# Test 2: well-formed overrides with skip + substitution → pass.
# ---------------------------------------------------------------------------
good="$WORKDIR/good.yml"
cat >"$good" <<'YAML'
version: 1
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: |
      This repo replaced keep-in-sync with a custom variant.
      Tracked in repo#42 for eventual convergence.
substitutions:
  phase_4b_default:
    value: fallback-only
    reason: |
      Deploy frequency is high (~5 PRs/day); always-on phase-4b
      routing latency outweighs the safety benefit on this repo.
YAML
if "$VALIDATOR" "$good" "$MANIFEST" >/dev/null 2>&1; then
  pass "well-formed overrides → exits 0"
else
  out=$("$VALIDATOR" "$good" "$MANIFEST" 2>&1 || true)
  fail "well-formed overrides should pass; got: $out"
fi

# ---------------------------------------------------------------------------
# Test 3: skip_paths entry with empty reason → fail (audit-trail).
# ---------------------------------------------------------------------------
empty_reason="$WORKDIR/empty-reason.yml"
cat >"$empty_reason" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: ""
YAML
if "$VALIDATOR" "$empty_reason" "$MANIFEST" >/dev/null 2>&1; then
  fail "empty reason should fail validation; validator passed"
else
  pass "empty reason → exits non-zero"
fi

# Whitespace-only reason — should also fail.
ws_reason="$WORKDIR/ws-reason.yml"
cat >"$ws_reason" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: "   "
YAML
if "$VALIDATOR" "$ws_reason" "$MANIFEST" >/dev/null 2>&1; then
  fail "whitespace-only reason should fail; validator passed"
else
  pass "whitespace-only reason → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 4: skip_paths references nonexistent manifest path → fail.
# ---------------------------------------------------------------------------
bad_path="$WORKDIR/bad-path.yml"
cat >"$bad_path" <<'YAML'
skip_paths:
  - path: scripts/does-not-exist.sh
    reason: legitimate-looking reason
YAML
if "$VALIDATOR" "$bad_path" "$MANIFEST" >/dev/null 2>&1; then
  fail "nonexistent skip path should fail; validator passed"
else
  pass "nonexistent skip path → exits non-zero"
fi

# A templated entry is selected by its Mergepath-side `.path` but writes its
# consumer-side `.dest`. Overrides describe consumer-owned divergence, so the
# destination is the only valid skip key. This live-shaped source/dest split
# prevents a validator-legal override that propagation silently ignores.
templated_dest_skip="$WORKDIR/templated-dest-skip.yml"
cat >"$templated_dest_skip" <<'YAML'
version: 1
skip_paths:
  - path: AGENTS.md
    reason: Consumer owns its rendered agent instructions.
YAML
if "$VALIDATOR" "$templated_dest_skip" "$MANIFEST" >/dev/null 2>&1; then
  pass "templated destination skip key → exits 0"
else
  out=$("$VALIDATOR" "$templated_dest_skip" "$MANIFEST" 2>&1 || true)
  fail "templated destination skip key should pass; got: $out"
fi

templated_source_skip="$WORKDIR/templated-source-skip.yml"
cat >"$templated_source_skip" <<'YAML'
version: 1
skip_paths:
  - path: examples/AGENTS.md
    reason: Source-side keys do not identify the consumer artifact.
YAML
if "$VALIDATOR" "$templated_source_skip" "$MANIFEST" >/dev/null 2>&1; then
  fail "templated source-side skip key should fail; validator passed"
else
  pass "templated source-side skip key → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 5: substitution references nonexistent marker → fail.
# ---------------------------------------------------------------------------
bad_sub="$WORKDIR/bad-sub.yml"
cat >"$bad_sub" <<'YAML'
substitutions:
  marker_that_isnt_in_manifest: any-value
YAML
if "$VALIDATOR" "$bad_sub" "$MANIFEST" >/dev/null 2>&1; then
  fail "nonexistent substitution marker should fail; validator passed"
else
  pass "nonexistent substitution marker → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 6: unknown top-level key → fail.
# ---------------------------------------------------------------------------
unknown_key="$WORKDIR/unknown-key.yml"
cat >"$unknown_key" <<'YAML'
skip_paths: []
unknown_field: oops
YAML
if "$VALIDATOR" "$unknown_key" "$MANIFEST" >/dev/null 2>&1; then
  fail "unknown top-level key should fail; validator passed"
else
  pass "unknown top-level key → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 7: malformed YAML → fail.
# ---------------------------------------------------------------------------
malformed="$WORKDIR/malformed.yml"
cat >"$malformed" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
   reason: bad indentation
   extra: -
YAML
if "$VALIDATOR" "$malformed" "$MANIFEST" >/dev/null 2>&1; then
  fail "malformed YAML should fail; validator passed"
else
  pass "malformed YAML → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 8: unsupported version → fail.
# ---------------------------------------------------------------------------
bad_version="$WORKDIR/bad-version.yml"
cat >"$bad_version" <<'YAML'
version: 999
skip_paths: []
YAML
if "$VALIDATOR" "$bad_version" "$MANIFEST" >/dev/null 2>&1; then
  fail "unsupported version should fail; validator passed"
else
  pass "unsupported version → exits non-zero"
fi

# ---------------------------------------------------------------------------
# apply-overrides.sh helper tests
# ---------------------------------------------------------------------------
# shellcheck source=../scripts/sync/apply-overrides.sh
. "$APPLY_LIB"

# Test 9: override_should_skip_path on a matching entry returns 0 with
# OVERRIDE_SKIP_REASON populated.
helper_override="$WORKDIR/helper-good.yml"
cat >"$helper_override" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: example skip
YAML
OVERRIDE_SKIP_REASON=""
if override_should_skip_path "$helper_override" "scripts/keep-in-sync.sh" \
   && [ "$OVERRIDE_SKIP_REASON" = "example skip" ]; then
  pass "override_should_skip_path matches and stores reason"
else
  fail "override_should_skip_path failed to match (reason=$OVERRIDE_SKIP_REASON)"
fi

# Test 10: override_should_skip_path on a non-matching path returns
# non-zero and clears OVERRIDE_SKIP_REASON.
OVERRIDE_SKIP_REASON="lingering"
if override_should_skip_path "$helper_override" "scripts/some-other.sh"; then
  fail "override_should_skip_path matched on non-listed path"
else
  if [ -z "$OVERRIDE_SKIP_REASON" ]; then
    pass "override_should_skip_path clears reason on miss"
  else
    fail "override_should_skip_path did not clear OVERRIDE_SKIP_REASON on miss"
  fi
fi

# Test 11: override_substitution_for returns 0 + value when key exists.
# Structured shape per the round 2 schema change (#228) — entries are
# `{value, reason}` maps, helper returns the .value field only.
sub_override="$WORKDIR/helper-sub.yml"
cat >"$sub_override" <<'YAML'
substitutions:
  phase_4b_default:
    value: fallback-only
    reason: test fixture
YAML
if val=$(override_substitution_for "$sub_override" "phase_4b_default") \
   && [ "$val" = "fallback-only" ]; then
  pass "override_substitution_for returns override value"
else
  fail "override_substitution_for didn't return expected value (got '$val')"
fi

# Test 12: override_substitution_for returns non-zero when key absent
# (caller falls back to manifest default).
if override_substitution_for "$sub_override" "missing_marker" >/dev/null 2>&1; then
  fail "override_substitution_for returned 0 for missing marker"
else
  pass "override_substitution_for returns non-zero for missing marker"
fi

# Test 13: helpers tolerate absent overrides file (return non-zero,
# don't abort the caller).
if override_should_skip_path "" "scripts/keep-in-sync.sh"; then
  fail "override_should_skip_path matched against empty file path"
else
  pass "override_should_skip_path tolerates empty file path"
fi
if override_substitution_for "/nonexistent/.sync-overrides.yml" "phase_4b_default" >/dev/null 2>&1; then
  fail "override_substitution_for matched against absent file"
else
  pass "override_substitution_for tolerates absent file"
fi

# Test 14: substitutions as a scalar (not a map) → fail validation,
# don't crash. CodeRabbit ⚠️ Major round 1 caught the underlying
# bug — yq's `length` aborts on scalar values.
scalar_subs="$WORKDIR/scalar-subs.yml"
cat >"$scalar_subs" <<'YAML'
substitutions: "this is a scalar, not a map"
YAML
out=$("$VALIDATOR" "$scalar_subs" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "must be a map"; then
  pass "scalar substitutions → clean diagnostic, not a crash"
else
  fail "scalar substitutions did not produce expected diagnostic; got: $out"
fi

# Test 15: skip_paths as a scalar → fail validation cleanly.
scalar_skip="$WORKDIR/scalar-skip.yml"
cat >"$scalar_skip" <<'YAML'
skip_paths: "scalar instead of sequence"
YAML
out=$("$VALIDATOR" "$scalar_skip" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "must be a sequence"; then
  pass "scalar skip_paths → clean diagnostic, not a crash"
else
  fail "scalar skip_paths did not produce expected diagnostic; got: $out"
fi

# Test 18: scalar at document root → fail validation cleanly.
# CodeRabbit ⚠️ Major round 2 caught: without a root-type guard,
# a top-level scalar passes silently because yq's `keys | .[]`
# returns nothing on non-map roots and rules 2-6 no-op.
scalar_root="$WORKDIR/scalar-root.yml"
cat >"$scalar_root" <<'YAML'
"not-a-map"
YAML
out=$("$VALIDATOR" "$scalar_root" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "document root must be a map"; then
  pass "scalar root → clean diagnostic, not a silent pass"
else
  fail "scalar root did not produce expected diagnostic; got: $out"
fi

# Sequence at document root → also fail.
seq_root="$WORKDIR/seq-root.yml"
cat >"$seq_root" <<'YAML'
- entry-one
- entry-two
YAML
out=$("$VALIDATOR" "$seq_root" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "document root must be a map"; then
  pass "sequence root → clean diagnostic"
else
  fail "sequence root did not produce expected diagnostic; got: $out"
fi

# Empty / null root → pass (empty file is the "no overrides" case).
null_root="$WORKDIR/null-root.yml"
echo "" >"$null_root"
if "$VALIDATOR" "$null_root" "$MANIFEST" >/dev/null 2>&1; then
  pass "empty document root → exits 0 (no overrides)"
else
  fail "empty document root should pass; validator returned non-zero"
fi

# Test 16 (renumbered to keep stable counts): marker name with special
# characters (`-`, `.`) — the apply-overrides.sh helpers must look it
# up via strenv-bracket, not yq's dot-path syntax. Round 1 CodeRabbit
# ⚠️ Major caught the bug.
specialchar_subs="$WORKDIR/specialchar.yml"
cat >"$specialchar_subs" <<'YAML'
substitutions:
  phase-4b.default:
    value: fallback-only
    reason: test
YAML
if val=$(override_substitution_for "$specialchar_subs" "phase-4b.default") \
   && [ "$val" = "fallback-only" ]; then
  pass "override_substitution_for handles special-char marker name (-, .)"
else
  fail "override_substitution_for failed on special-char marker (got '$val')"
fi

# Test 22: bare-scalar substitution → fail validation (the schema-contract
# fix from #228 round 2; nathanpayne-codex caught that the old shape
# `marker: value` shipped without an audit-trail reason).
bare_sub="$WORKDIR/bare-sub.yml"
cat >"$bare_sub" <<'YAML'
substitutions:
  phase_4b_default: fallback-only
YAML
out=$("$VALIDATOR" "$bare_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "must be a map with 'value' and 'reason'"; then
  pass "bare-scalar substitution → rejected with clear diagnostic"
else
  fail "bare-scalar substitution should be rejected; got: $out"
fi

# Test 23: substitution entry with `value` but no `reason` → fail.
no_reason_sub="$WORKDIR/no-reason-sub.yml"
cat >"$no_reason_sub" <<'YAML'
substitutions:
  phase_4b_default:
    value: fallback-only
YAML
out=$("$VALIDATOR" "$no_reason_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing or empty 'reason' field"; then
  pass "substitution without reason → rejected"
else
  fail "substitution without reason should be rejected; got: $out"
fi

# Test 24: substitution entry with empty (whitespace) reason → fail.
ws_reason_sub="$WORKDIR/ws-reason-sub.yml"
cat >"$ws_reason_sub" <<'YAML'
substitutions:
  phase_4b_default:
    value: fallback-only
    reason: "   "
YAML
out=$("$VALIDATOR" "$ws_reason_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing or empty 'reason' field"; then
  pass "substitution with whitespace-only reason → rejected"
else
  fail "substitution with whitespace reason should be rejected; got: $out"
fi

# Test 25: substitution entry with `reason` but no `value` → fail.
no_value_sub="$WORKDIR/no-value-sub.yml"
cat >"$no_value_sub" <<'YAML'
substitutions:
  phase_4b_default:
    reason: forgot the value field
YAML
out=$("$VALIDATOR" "$no_value_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing 'value' field"; then
  pass "substitution without value → rejected"
else
  fail "substitution without value should be rejected; got: $out"
fi

# Test 26: substitution entry with `value: null` → fail (Rule 7
# extension; CodeRabbit ⚠️ Major round 4 caught that null/empty
# values were allowed even though the {value, reason} contract says
# non-empty).
null_value_sub="$WORKDIR/null-value-sub.yml"
cat >"$null_value_sub" <<'YAML'
version: 1
substitutions:
  phase_4b_default:
    value: null
    reason: oops, forgot the actual value
YAML
out=$("$VALIDATOR" "$null_value_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing or empty 'value' field"; then
  pass "substitution with value: null → rejected"
else
  fail "substitution with null value should be rejected; got: $out"
fi

# Test 27: substitution entry with `value: ""` → fail.
empty_value_sub="$WORKDIR/empty-value-sub.yml"
cat >"$empty_value_sub" <<'YAML'
version: 1
substitutions:
  phase_4b_default:
    value: ""
    reason: ditto, but with explicit empty string
YAML
out=$("$VALIDATOR" "$empty_value_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing or empty 'value' field"; then
  pass "substitution with value: \"\" → rejected"
else
  fail "substitution with empty value should be rejected; got: $out"
fi

# Test 28: substitution entry with whitespace-only `value` → fail.
ws_value_sub="$WORKDIR/ws-value-sub.yml"
cat >"$ws_value_sub" <<'YAML'
version: 1
substitutions:
  phase_4b_default:
    value: "   "
    reason: whitespace value
YAML
out=$("$VALIDATOR" "$ws_value_sub" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing or empty 'value' field"; then
  pass "substitution with whitespace-only value → rejected"
else
  fail "substitution with whitespace value should be rejected; got: $out"
fi

# Test 29: non-empty overrides file missing `version` → fail (Rule 3
# now requires version on any non-empty document; CodeRabbit ⚠️ Major
# round 4).
no_version="$WORKDIR/no-version.yml"
cat >"$no_version" <<'YAML'
skip_paths: []
YAML
out=$("$VALIDATOR" "$no_version" "$MANIFEST" 2>&1 || true)
if echo "$out" | grep -q "missing required top-level key: version"; then
  pass "non-empty file without version → rejected"
else
  fail "missing version should be rejected; got: $out"
fi

# Test 30: apply-overrides.sh treats null/empty .value as "no override"
# (returns non-zero), so callers fall back to the manifest default
# rather than propagating a literal null. CodeRabbit ⚠️ Major round 4.
null_value_apply="$WORKDIR/null-value-apply.yml"
cat >"$null_value_apply" <<'YAML'
substitutions:
  phase_4b_default:
    value: null
    reason: shouldn't propagate
YAML
if override_substitution_for "$null_value_apply" "phase_4b_default" >/dev/null 2>&1; then
  fail "override_substitution_for should return non-zero for null value"
else
  pass "override_substitution_for treats null .value as no override"
fi

empty_value_apply="$WORKDIR/empty-value-apply.yml"
cat >"$empty_value_apply" <<'YAML'
substitutions:
  phase_4b_default:
    value: ""
    reason: empty string shouldn't propagate either
YAML
if override_substitution_for "$empty_value_apply" "phase_4b_default" >/dev/null 2>&1; then
  fail "override_substitution_for should return non-zero for empty value"
else
  pass "override_substitution_for treats empty .value as no override"
fi

# Test 31: a malformed propagation manifest must report the parse failure,
# not silently collapse to the distinct "no paths declared" condition. The
# validator only reads manifest paths when skip_paths is non-empty, so keep a
# valid override in this fixture to exercise that branch.
malformed_manifest="$WORKDIR/malformed-manifest.yml"
cat >"$malformed_manifest" <<'YAML'
version: 1
paths:
  - path: scripts/keep-in-sync.sh
   type: canonical
YAML
manifest_parse_override="$WORKDIR/manifest-parse-override.yml"
cat >"$manifest_parse_override" <<'YAML'
version: 1
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: exercise manifest parsing
YAML
out=$("$VALIDATOR" "$manifest_parse_override" "$malformed_manifest" 2>&1 || true)
if echo "$out" | grep -q "failed to parse manifest" \
   && ! echo "$out" | grep -q "has no paths declared"; then
  pass "malformed manifest → parse failure is preserved"
else
  fail "malformed manifest should preserve its parse failure; got: $out"
fi

empty_paths_manifest="$WORKDIR/empty-paths-manifest.yml"
cat >"$empty_paths_manifest" <<'YAML'
version: 1
paths: []
YAML
out=$("$VALIDATOR" "$manifest_parse_override" "$empty_paths_manifest" 2>&1 || true)
if echo "$out" | grep -q "has no paths declared" \
   && ! echo "$out" | grep -q "failed to parse manifest"; then
  pass "valid empty manifest paths → distinct no-paths failure is preserved"
else
  fail "valid empty manifest paths should retain the no-paths diagnostic; got: $out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_sync_overrides: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
