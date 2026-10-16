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

# Effective requires closure (#1041): actual validator exit contracts and
# shared metadata proof, with consumer scope and carrier union controls.
closure_manifest="$WORKDIR/closure.yml"
cat >"$closure_manifest" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
  - {name: beta, repo: example/beta}
paths:
  - {path: workflow.yml, type: canonical, consumers: [alpha], requires: [kit/tool]}
  - {path: kit, type: kit, consumers: all}
  - {path: kit/tool, type: canonical, consumers: [beta]}
  - {path: unused, type: canonical, consumers: []}
  - {path: independent, type: canonical, consumers: all}
  - {path: template.in, dest: runtime/tool, type: templated, consumers: all}
  - {path: caller, type: canonical, consumers: all, requires: [template.in]}
YAML
closure_skip="$WORKDIR/closure-skip.yml"
cat >"$closure_skip" <<'YAML'
version: 1
skip_paths:
  - {path: kit, reason: custom kit}
YAML
closure_expect_validator() {
  local expected=$1; shift
  local rc=0 output
  output=$("$VALIDATOR" "$@" 2>&1) || rc=$?
  if [ "$rc" = "$expected" ]; then pass "closure validator exit $expected: $*";
  else fail "closure validator expected $expected got $rc: $output"; fi
  CLOSURE_OUTPUT=$output
}
closure_expect_validator 1 "$closure_skip" "$closure_manifest" alpha
[[ "$CLOSURE_OUTPUT" == *'kit/tool (required by workflow.yml)'* ]] \
  || fail "contradiction must name required and requiring paths: $CLOSURE_OUTPUT"
closure_expect_validator 0 "$closure_skip" "$closure_manifest" beta
closure_expect_validator 2 "$closure_skip" "$closure_manifest"
[[ "$CLOSURE_OUTPUT" == *'depends on consumer identity'* ]] || fail "ambiguous scope needs explicit selector"
closure_expect_validator 2 "$closure_skip" "$closure_manifest" unknown
# Empty/no-skip remains compatible even without a selector (or an irrelevant
# selector); closure does not invent a consumer for a no-divergence document.
closure_expect_validator 0 "$WORKDIR/absent.yml" "$closure_manifest"
printf 'version: 1\nskip_paths: []\n' >"$WORKDIR/no-skip.yml"
closure_expect_validator 0 "$WORKDIR/no-skip.yml" "$closure_manifest" unknown
# A skipped requiring entry creates no obligation; the independent skip is valid.
printf '  - {path: workflow.yml, reason: custom workflow}\n' >>"$closure_skip"
closure_expect_validator 0 "$closure_skip" "$closure_manifest"
printf 'version: 1\nskip_paths:\n  - {path: independent, reason: unrelated}\n' >"$closure_skip"
closure_expect_validator 0 "$closure_skip" "$closure_manifest"
# Template coverage uses logical .path, but skip ownership uses consumer .dest.
printf 'version: 1\nskip_paths:\n  - {path: runtime/tool, reason: custom runtime}\n' >"$closure_skip"
closure_expect_validator 1 "$closure_skip" "$closure_manifest"
[[ "$CLOSURE_OUTPUT" == *'template.in (required by caller)'* ]] || fail "templated contradiction mapping lost"
# Union: when the exact carrier applies to alpha too, an active carrier wins.
yq -i '.paths[2].consumers = "all"' "$closure_manifest"
printf 'version: 1\nskip_paths:\n  - {path: kit, reason: custom kit}\n' >"$closure_skip"
closure_expect_validator 0 "$closure_skip" "$closure_manifest"
printf '  - {path: kit/tool, reason: custom exact}\n' >>"$closure_skip"
closure_expect_validator 2 "$closure_skip" "$closure_manifest"
closure_expect_validator 1 "$closure_skip" "$closure_manifest" alpha
# A selected slice checks its own direct edges; an explicit empty selection
# checks none. Full validation checks all effective edges, including cycles.
override_requires_load "$closure_manifest" "$closure_skip" || fail 'closure fixture failed metadata load'
if override_requires_check alpha independent; then pass 'selected independent entry remains valid'; else fail "$OVERRIDE_REQUIRES_DETAIL"; fi
if override_requires_check alpha ''; then pass 'empty selected slice is empty'; else fail "$OVERRIDE_REQUIRES_DETAIL"; fi
if override_requires_check alpha workflow.yml; then fail 'selected requirer bypassed skip'; else pass 'selected requirer rejects missing carrier'; fi
# A containing kit covers a descendant, never a neighboring textual prefix.
cat >"$WORKDIR/boundary-closure.yml" <<'YAML'
consumers: [{name: alpha}]
paths:
  - {path: caller, type: canonical, consumers: all, requires: [kitten/tool]}
  - {path: kit, type: kit, consumers: all}
YAML
override_requires_load "$WORKDIR/boundary-closure.yml" '' || fail 'boundary metadata rejected'
rc=0; override_requires_check alpha || rc=$?
[ "$rc" = 1 ] && pass 'kit prefix requires component boundary' || fail 'neighbor prefix supplied coverage'
# All effective direct edges close a chain or cycle without recursive execution.
cat >"$WORKDIR/chain-closure.yml" <<'YAML'
consumers: [{name: alpha}]
paths:
  - {path: a, type: canonical, consumers: all, requires: [b]}
  - {path: b, type: canonical, consumers: all, requires: [c]}
  - {path: c, type: canonical, consumers: all, requires: [a]}
YAML
override_requires_load "$WORKDIR/chain-closure.yml" '' || fail 'cycle metadata rejected'
if override_requires_check alpha; then pass 'closed direct-edge cycle passes'; else fail "$OVERRIDE_REQUIRES_DETAIL"; fi
printf 'version: 1\nskip_paths:\n  - {path: c, reason: independent override}\n' >"$WORKDIR/chain-skip.yml"
override_requires_load "$WORKDIR/chain-closure.yml" "$WORKDIR/chain-skip.yml" || fail 'chain skip rejected'
rc=0; override_requires_check alpha || rc=$?
[ "$rc" = 1 ] && [[ "$OVERRIDE_REQUIRES_DETAIL" == *'c (required by b)'* ]] \
  && pass 'full effective graph checks intermediate direct edge' || fail 'intermediate obligation lost'
# Canonical/kit .dest metadata is ignored, even if it cannot be represented
# as a TSV cell. Only templated entries own and validate destinations.
cat >"$WORKDIR/ignored-dest-closure.yml" <<'YAML'
consumers: [{name: alpha}]
paths:
  - path: caller
    type: canonical
    consumers: all
    requires: [kit/tool]
    dest: "ignored\tcanonical\tall\tignored\nforged\tkit\tall\tforged"
  - {path: kit, type: kit, consumers: all, dest: {ignored: [not, a, target]}}
YAML
if override_requires_load "$WORKDIR/ignored-dest-closure.yml" ''; then
  expected_entries=$'caller\tcanonical\tall\tcaller\nkit\tkit\tall\tkit'
  [ "$OVERRIDE_REQUIRES_ENTRIES" = "$expected_entries" ] \
    && pass 'canonical/kit ignored dest cannot forge serialized entries' \
    || fail "ignored dest altered coverage rows: $OVERRIDE_REQUIRES_ENTRIES"
  if override_requires_check alpha; then pass 'ignored dest retains real kit coverage'; else fail "$OVERRIDE_REQUIRES_DETAIL"; fi
else
  fail 'ignored canonical/kit destination metadata changed target semantics'
fi
for invalid_dest in '"invalid\tcell\nforged"' '{not: a-string}'; do
  printf 'consumers: [{name: alpha}]\npaths:\n  - {path: template.in, type: templated, consumers: all, dest: %s}\n' "$invalid_dest" >"$WORKDIR/invalid-template-dest.yml"
  rc=0; override_requires_load "$WORKDIR/invalid-template-dest.yml" '' || rc=$?
  [ "$rc" = 2 ] && pass 'templated invalid destination rejected' || fail 'invalid templated dest entered serialization'
done
# NUL must be rejected before command substitution can silently remove it.
# Parse YAML's \0 escape, rather than an expression-string \u escape that
# yq passes through literally. Verify the written field before testing load.
printf '"al\\0pha"\n' >"$WORKDIR/nul-scalar.yml"
for nul_field in '.paths[0].path' '.paths[5].dest' '.paths[0].requires' '.consumers[0].name' '.paths[0].consumers'; do
  cp "$closure_manifest" "$WORKDIR/nul-closure.yml"
  nul_value='load(strenv(OVERRIDE_NUL_SCALAR))'
  nul_read=$nul_field
  case "$nul_field" in
    '.paths[0].requires'|'.paths[0].consumers')
      nul_value="[$nul_value]"; nul_read="${nul_field}[0]" ;;
  esac
  OVERRIDE_NUL_SCALAR="$WORKDIR/nul-scalar.yml" yq -i "$nul_field = $nul_value" "$WORKDIR/nul-closure.yml"
  if ! yq -e "$nul_read | test(\"\\x00\")" "$WORKDIR/nul-closure.yml" >/dev/null; then
    fail "NUL fixture did not populate $nul_read"
    continue
  fi
  rc=0; override_requires_load "$WORKDIR/nul-closure.yml" '' || rc=$?
  [ "$rc" = 2 ] && pass "strict closure rejects genuine NUL field: $nul_field" \
    || fail "NUL field reached serialization: $nul_field"
done
cat >"$WORKDIR/nul-skip.yml" <<'YAML'
skip_paths:
  - {path: "kit/\0tool", reason: custom}
YAML
if ! yq -e '.skip_paths[0].path | test("\x00")' "$WORKDIR/nul-skip.yml" >/dev/null; then
  fail 'NUL skip fixture did not contain NUL'
fi
rc=0; override_requires_load "$closure_manifest" "$WORKDIR/nul-skip.yml" || rc=$?
[ "$rc" = 2 ] && pass 'strict closure rejects NUL skip path' || fail 'NUL skip reached serialization'
# Ignored non-templated metadata remains ignored even when it contains NUL.
for ignored_type in canonical kit; do
  printf 'consumers: [{name: alpha}]\npaths:\n  - {path: ordinary, type: %s, consumers: all, dest: "ignored\\0destination"}\n' "$ignored_type" >"$WORKDIR/nul-ignored-dest.yml"
  if ! yq -e '.paths[0].dest | test("\x00")' "$WORKDIR/nul-ignored-dest.yml" >/dev/null; then
    fail "NUL ignored $ignored_type fixture did not contain NUL"
    continue
  fi
  if override_requires_load "$WORKDIR/nul-ignored-dest.yml" ''; then
    expected_entries=$(printf 'ordinary\t%s\tall\tordinary' "$ignored_type")
    [ "$OVERRIDE_REQUIRES_ENTRIES" = "$expected_entries" ] \
      && pass "NUL in ignored $ignored_type dest cannot alter entries" \
      || fail "ignored $ignored_type NUL destination entered serialization"
  else
    fail "ignored $ignored_type NUL destination became applicable metadata"
  fi
done
# Malformed dependency metadata must never become a successful empty graph.
for bad in 'requires: kit/tool' 'requires: [7]' 'requires: null'; do
  printf 'consumers: [{name: alpha}]\npaths:\n  - {path: a, type: canonical, consumers: all, %s}\n' "$bad" >"$WORKDIR/bad-closure.yml"
  rc=0; override_requires_load "$WORKDIR/bad-closure.yml" '' || rc=$?
  [ "$rc" = 2 ] && pass "strict metadata rejects $bad" || fail "bad metadata accepted: $bad"
done
printf 'version: 1\nskip_paths: wrong\n' >"$WORKDIR/bad-closure-overrides.yml"
rc=0; override_requires_load "$closure_manifest" "$WORKDIR/bad-closure-overrides.yml" || rc=$?
[ "$rc" = 2 ] && pass 'strict closure rejects malformed skip set' || fail 'malformed skips became empty graph'
# Old permissive API retains parse-error/no-override behavior independently.
if override_should_skip_path "$WORKDIR/bad-closure-overrides.yml" kit; then fail 'old malformed matcher changed'; else pass 'old matcher default preserved'; fi

# Review1: destination omission, selected delivery and indexed metadata proof.
review_manifest="$WORKDIR/review-closure.yml"
review_skip="$WORKDIR/review-skip.yml"
review_check() {
  local expected=$1; shift
  local actual=0
  override_requires_check "$@" >"$WORKDIR/review-stdout" || actual=$?
  if [ "$actual" = "$expected" ] && [ ! -s "$WORKDIR/review-stdout" ]; then
    pass "indexed closure exit $expected: $*"
  else
    fail "indexed closure expected $expected got $actual: $OVERRIDE_REQUIRES_DETAIL"
  fi
  if [ "$actual" != 0 ] && [ -n "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ]; then
    fail 'failed metadata proof exposed partial effective edges'
  fi
}
# (1–3) Omission defaults to path; present invalid values do not default.
cat >"$review_manifest" <<'YAML'
consumers: [{name: alpha}]
paths:
  - {path: template.in, type: templated, consumers: all}
YAML
if override_requires_load "$review_manifest" ''; then
  [ "$OVERRIDE_REQUIRES_ENTRIES" = $'template.in\ttemplated\tall\ttemplate.in' ] \
    && pass 'omitted templated dest resolves to path' || fail 'omitted dest serialized incorrectly'
  review_check 0 alpha
else fail 'omitted templated dest rejected'; fi
cat >>"$review_manifest" <<'YAML'
  - {path: caller, type: canonical, consumers: all, requires: [template.in]}
YAML
printf 'skip_paths: [{path: template.in, reason: custom}]\n' >"$review_skip"
override_requires_load "$review_manifest" "$review_skip" || fail 'omitted-dest carrier fixture rejected'
review_check 1 alpha
for invalid_dest in null true 7 '{}' '""' '"bad\tcell"' '"bad\ncell"' '"bad\0cell"'; do
  printf 'consumers: [{name: alpha}]\npaths:\n  - {path: template.in, type: templated, consumers: all, dest: %s}\n' "$invalid_dest" >"$WORKDIR/review-invalid-dest.yml"
  rc=0; override_requires_load "$WORKDIR/review-invalid-dest.yml" '' || rc=$?
  [ "$rc" = 2 ] && [ -z "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ] \
    && pass "present invalid dest cannot default: $invalid_dest" || fail "invalid dest accepted: $invalid_dest"
done
# (4) Ignored canonical/kit malformed and genuine-NUL destinations above stay
# applicable only through path; these earlier assertions are not weakened.
# (5–8) Exact and kit carriers form a union for the delivered requirer too.
cat >"$review_manifest" <<'YAML'
consumers: [{name: alpha}, {name: beta}]
paths:
  - {path: scripts/a.sh, type: canonical, consumers: [alpha], requires: [dep]}
  - {path: scripts/, type: kit, consumers: [alpha]}
  - {path: dep, type: canonical, consumers: all}
  - {path: unrelated, type: canonical, consumers: all}
YAML
cat >"$review_skip" <<'YAML'
skip_paths:
  - {path: scripts/a.sh, reason: custom exact}
  - {path: dep, reason: custom dependency}
YAML
override_requires_load "$review_manifest" "$review_skip" || fail 'delivery union fixture rejected'
review_check 1 alpha
review_check 1 alpha scripts/
[[ "$OVERRIDE_REQUIRES_DETAIL" == *'dep (required by scripts/a.sh)'* ]] \
  || fail 'selected kit lost descendant diagnostic'
printf '  - {path: scripts/, reason: custom whole kit}\n' >>"$review_skip"
override_requires_load "$review_manifest" "$review_skip" || fail 'all requiring carriers fixture rejected'
review_check 0 alpha
[ -z "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ] || fail 'fully skipped requirer retained edges'
# A surviving required carrier supplies logical metadata coverage. Its actual
# consumer bytes are still checked independently by the sync gate suite.
yq -i '.paths += [{"path": "deps/tool", "type": "canonical", "consumers": "all"}, {"path": "deps", "type": "kit", "consumers": "all"}] | .paths[0].requires = ["deps/tool"]' "$review_manifest"
printf 'skip_paths: [{path: deps/tool, reason: exact}, {path: scripts/a.sh, reason: exact}]\n' >"$review_skip"
override_requires_load "$review_manifest" "$review_skip" || fail 'required carrier union rejected'
review_check 0 alpha scripts/
[ "$OVERRIDE_REQUIRES_ACTIVE_EDGES" = $'scripts/a.sh\tdeps/tool' ] \
  && pass 'selected kit publishes declared descendant edge' || fail 'shared selected edge missing'
# (9–10) Empty/unrelated selection, scope and component boundaries are literal.
review_check 0 alpha unrelated
[ -z "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ] || fail 'unrelated selection activated descendant'
review_check 0 alpha ''
review_check 0 beta scripts/
review_check 0 alpha $'scripts/\tunexpected'
review_check 0 alpha scripts-extra/
# A neighboring kit cannot deliver the requiring file either.
yq -i '.paths[1].path = "scripts-extra/"' "$review_manifest"
override_requires_load "$review_manifest" "$review_skip" || fail 'neighbor carrier fixture rejected'
review_check 0 alpha
[ -z "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ] || fail 'neighbor kit supplied requiring delivery'
# (11) A selected kit carrying template SOURCE is not its skipped DEST.
cat >"$review_manifest" <<'YAML'
consumers: [{name: alpha}]
paths:
  - {path: templates/tool.in, dest: runtime/tool, type: templated, consumers: all, requires: [dep]}
  - {path: templates/, type: kit, consumers: all}
  - {path: dep, type: canonical, consumers: all}
YAML
printf 'skip_paths: [{path: runtime/tool, reason: custom}, {path: dep, reason: custom}]\n' >"$review_skip"
override_requires_load "$review_manifest" "$review_skip" || fail 'rendered target fixture rejected'
review_check 0 alpha templates/
[ -z "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ] || fail 'template source kit reactivated rendered destination'
# (12) Literal backslashes, spaces and regexp punctuation survive stdin.
cat >"$review_manifest" <<'YAML'
consumers: [{name: alpha}]
paths:
  - {path: 'caller \.[x]', type: canonical, consumers: all, requires: ['kit \.[x]/tool']}
  - {path: 'kit \.[x]/', type: kit, consumers: all}
YAML
override_requires_load "$review_manifest" '' || fail 'literal metadata fixture rejected'
review_check 0 alpha 'caller \.[x]'
[ "$OVERRIDE_REQUIRES_ACTIVE_EDGES" = $'caller \\.[x]\tkit \\.[x]/tool' ] \
  && pass 'literal metadata retained in effective edges' || fail 'literal metadata changed in processor'
# TSV forbids tab/newline/NUL, but not awk SUBSEP. This accepted path must not
# collide with another path/edge-index composite. Edge order remains literal.
cat >"$review_manifest" <<'YAML'
consumers: [{name: alpha}]
paths:
  - {path: "a\x1c1", type: canonical, consumers: all, requires: [ok]}
  - {path: a, type: canonical, consumers: all, requires: [missing-first, missing-second]}
  - {path: ok, type: canonical, consumers: all}
YAML
override_requires_load "$review_manifest" '' || fail 'SUBSEP literal fixture rejected'
review_check 0 alpha $'a\0341'
[ "$OVERRIDE_REQUIRES_ACTIVE_EDGES" = $'a\0341\tok' ] || fail 'length-framed key collision changed edge'
review_check 1 alpha
[[ "$OVERRIDE_REQUIRES_DETAIL" == *'missing-first (required by a)'* ]] \
  && pass 'first manifest edge diagnostic remains stable' || fail 'edge diagnostic reordered'
# (13) Processor absence/failure/empty success cannot clear stale proof.
# Function shadowing is local to a subshell and does not change the host PATH.
for processor_mode in absent failed empty; do
  if (
    initial_fail=$FAIL
    override_requires_load "$review_manifest" '' || exit 91
    OVERRIDE_REQUIRES_ACTIVE_EDGES=stale
    case "$processor_mode" in
      absent) command() { if [ "$*" = '-v awk' ]; then return 1; fi; builtin command "$@"; } ;;
      failed) awk() { return 1; } ;;
      empty) awk() { return 0; } ;;
    esac
    review_check 2 alpha
    [ "$FAIL" -eq "$initial_fail" ]
  ); then pass "processor $processor_mode fails closed without stale edges";
  else fail "processor $processor_mode accepted unavailable proof"; fi
done
# (14) A bounded graph with a final contradiction cannot truncate to success.
{
  printf 'consumers: [{name: alpha}]\npaths:\n'
  for ((review_i=0; review_i<300; review_i++)); do
    printf '  - {path: node%s, type: canonical, consumers: all, requires: [node%s]}\n' "$review_i" "$((review_i+1))"
  done
} >"$review_manifest"
override_requires_load "$review_manifest" '' || fail 'bounded graph fixture rejected'
review_check 1 alpha
[[ "$OVERRIDE_REQUIRES_DETAIL" == *'node300 (required by node299)'* ]] \
  && pass 'indexed graph retains late contradiction' || fail 'bounded graph truncated or reordered'

# Review2: an exact applicable template denotes its rendered dependency.
# A raw containing source kit cannot satisfy a skipped rendered destination.
identity_manifest="$WORKDIR/template-identity.yml"
identity_skip="$WORKDIR/template-identity-skip.yml"
cat >"$identity_manifest" <<'YAML'
consumers: [{name: alpha}, {name: beta}]
paths:
  - {path: caller, type: canonical, consumers: all, requires: [templates/logical.in]}
  - {path: templates/logical.in, source: templates/physical.in, dest: runtime/tool, type: templated, consumers: all}
  - {path: templates/, type: kit, consumers: all}
YAML
printf 'skip_paths: [{path: runtime/tool, reason: custom rendered dependency}]\n' >"$identity_skip"
override_requires_load "$identity_manifest" "$identity_skip" || fail 'template identity fixture rejected'
review_check 1 alpha
[[ "$OVERRIDE_REQUIRES_DETAIL" == *'templates/logical.in (required by caller)'* ]] \
  || fail 'skipped rendered dependency diagnostic lost its logical key'
override_requires_load "$identity_manifest" '' || fail 'unskipped template identity rejected'
review_check 0 alpha caller
[ "$OVERRIDE_REQUIRES_ACTIVE_EDGES" = $'caller\ttemplates/logical.in' ] || fail 'unskipped template edge lost'
# Mapping applicability belongs to this consumer; another consumer's template
# must not shadow ordinary raw kit coverage here.
yq -i '.paths[1].consumers = ["beta"]' "$identity_manifest"
override_requires_load "$identity_manifest" "$identity_skip" || fail 'scoped template identity rejected'
review_check 0 alpha
review_check 1 beta
# An omitted destination still denotes a render at its logical path.
yq -i '.paths[1].consumers = "all" | del(.paths[1].dest)' "$identity_manifest"
printf 'skip_paths: [{path: templates/logical.in, reason: custom path-preserving render}]\n' >"$identity_skip"
override_requires_load "$identity_manifest" "$identity_skip" || fail 'path-preserving template identity rejected'
review_check 1 alpha
# Ordinary exact/kit alternative coverage remains a union.
yq -i '.paths[1].type = "canonical"' "$identity_manifest"
override_requires_load "$identity_manifest" "$identity_skip" || fail 'plain dependency union fixture rejected'
review_check 0 alpha
# Classification precedes skip filtering and does not depend on row order.
yq -i '.paths[1].type = "templated" | .paths = [.paths[2], .paths[1], .paths[0]]' "$identity_manifest"
override_requires_load "$identity_manifest" "$identity_skip" || fail 'reordered template identity rejected'
review_check 1 alpha

# Review3: closure must use the materializer's actual first serialized reason
# line, not a second interpretation of YAML strings or duplicate skip paths.
reason_manifest="$WORKDIR/reason-parity-manifest.yml"
reason_skip="$WORKDIR/reason-parity-skip.yml"
reason_parity_case() {  # label, reader rc, check rc, first YAML reason, [second]
  local label=$1 expected_reader=$2 expected_check=$3 first=$4
  local target=${REASON_PARITY_TARGET:-a.sh} rc=0 expected_skips
  {
    printf 'consumers: [{name: alpha}]\npaths:\n'
    printf "  - {path: '%s', type: canonical, consumers: all, requires: [b.sh]}\n" "$target"
    printf '  - {path: b.sh, type: canonical, consumers: all}\n'
  } >"$reason_manifest"
  {
    printf "skip_paths:\n  - path: '%s'\n    reason: %s\n" "$target" "$first"
    if [ "$#" -eq 5 ]; then
      printf "  - path: '%s'\n    reason: %s\n" "$target" "$5"
    fi
    printf '  - {path: b.sh, reason: ordinary dependency skip}\n'
  } >"$reason_skip"
  override_should_skip_path "$reason_skip" "$target" || rc=$?
  [ "$rc" = "$expected_reader" ] \
    && pass "reason parity $label: authoritative reader result" \
    || fail "reason parity $label: reader expected $expected_reader got $rc"
  OVERRIDE_SKIP_REASON=reason-parity-preserved
  if ! override_requires_load "$reason_manifest" "$reason_skip"; then
    fail "reason parity $label: validated metadata rejected"
    return
  fi
  expected_skips=b.sh
  if [ "$expected_reader" = 0 ]; then expected_skips="$target"$'\n'b.sh; fi
  [ "$OVERRIDE_REQUIRES_SKIPS" = "$expected_skips" ] \
    && [ "$OVERRIDE_SKIP_REASON" = reason-parity-preserved ] \
    && pass "reason parity $label: exact distinct skips and reader output isolation" \
    || fail "reason parity $label: skip list/output isolation changed"
  rc=0
  override_requires_check alpha || rc=$?
  [ "$rc" = "$expected_check" ] && [ -z "$OVERRIDE_REQUIRES_ACTIVE_EDGES" ] \
    && pass "reason parity $label: active obligation matches delivered artifacts" \
    || fail "reason parity $label: closure expected $expected_check got $rc or leaked partial edges"
  if [ "$expected_check" = 1 ]; then
    [[ "$OVERRIDE_REQUIRES_DETAIL" == *"b.sh (required by $target)"* ]] \
      || fail "reason parity $label: requiring/dependency diagnostic changed"
  fi
}
reason_parity_case literal-null 1 1 '"null"'
reason_parity_case empty-string 1 1 '""'
reason_parity_case null-trailing-newline 1 1 '"null\n"'
reason_parity_case null-first-line 1 1 '"null\nlater rationale"'
reason_parity_case leading-newline 1 1 '"\nlater rationale"'
reason_parity_case newline-only 1 1 '"\n"'
reason_parity_case ordinary-multiline 0 0 '"ordinary\nnull"'
reason_parity_case ordinary-trailing-newline 0 0 '"ordinary\n"'
# This checks the permissive application reader, not the validator's stricter
# whitespace-only reason schema. Neither API/schema is changed by closure.
reason_parity_case whitespace-reader-compatibility 0 0 '"   "'
reason_parity_case duplicate-null-first 1 1 '"null"' '"ordinary"'
reason_parity_case duplicate-empty-first 1 1 '""' '"ordinary"'
reason_parity_case duplicate-valid-first 0 0 '"ordinary"' '"null"'
REASON_PARITY_TARGET='odd "quote"\path.sh' \
  reason_parity_case literal-path 1 1 '"null"' '"ordinary"'
# No-skip metadata keeps the same active direct edge and does not disturb the
# permissive reader's cross-call output variable.
for reason_empty in absent empty; do
  reason_file="$WORKDIR/reason-$reason_empty.yml"
  if [ "$reason_empty" = empty ]; then printf 'skip_paths: []\n' >"$reason_file"; fi
  OVERRIDE_SKIP_REASON=reason-parity-preserved
  rc=0
  override_requires_load "$reason_manifest" "$reason_file" || rc=$?
  [ "$rc" = 0 ] && [ -z "$OVERRIDE_REQUIRES_SKIPS" ] \
    && [ "$OVERRIDE_SKIP_REASON" = reason-parity-preserved ] \
    || fail "reason parity $reason_empty: no-skip load changed"
  rc=0
  override_requires_check alpha || rc=$?
  [ "$rc" = 0 ] && [ "$OVERRIDE_REQUIRES_ACTIVE_EDGES" = $'odd "quote"\path.sh\tb.sh' ] \
    && pass "reason parity $reason_empty: no-skip edge preserved" \
    || fail "reason parity $reason_empty: expected active direct edge"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_sync_overrides: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
