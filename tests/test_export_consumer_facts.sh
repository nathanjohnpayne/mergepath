#!/usr/bin/env bash
# tests/test_export_consumer_facts.sh
#
# Regression-guard for the yq filter inside
# scripts/sync-to-downstream.sh's `export_consumer_facts()`. The
# initial Phase B2 (#316) implementation used a mikefarah/yq-
# incompatible `if (tag == "!!seq") then ... else ... end` form
# that silently emitted nothing — every templated render fell
# through to the "no frameworks" baseline because
# MERGEPATH_FACT_* was never exported. Phase D's swipewatch canary
# fell-positive on the bug because swipewatch happens to declare
# `frameworks: []` (rendered output is the same with or without
# the facts loaded). device-platform-reporting's canary surfaced
# the real failure: its `frameworks: [react]` should activate the
# React block, but rendered to the JS baseline only.
#
# This test runs the EXACT yq filter from export_consumer_facts
# against three fixture consumer profiles (seq fact, scalar fact,
# empty seq fact, no facts at all) and asserts the output shape.
# The lib's yq invocation and this test's yq invocation must stay
# in sync — both carry a "keep in sync with tests/test_export_consumer_facts.sh"
# comment for the next contributor.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/sync-to-downstream.sh"
# The yq filter moved to scripts/lib/manifest-fact-helpers.sh in
# mergepath#323 so both sync-to-downstream.sh and
# scripts/workflow/verify-propagation-pr.sh can load consumer facts
# from a shared helper without duplicating the filter. The regression-
# guard greps the lib file now; we still confirm sync-to-downstream.sh
# sources the lib so the wiring can't silently drift.
LIB="$ROOT/scripts/lib/manifest-fact-helpers.sh"

[[ -r "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 1; }
[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/export-facts-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Fixture manifest with consumers exercising the value-type matrix.
# `with_322_facts` covers the mergepath#322 facts vocabulary (testing
# scalar, jsx_in_js bool, react_compiler bool) to regression-guard
# the export pipeline against the bool-as-string serialization that
# the lib's `<key> == true` / `!<key>` expressions depend on.
cat > "$WORKDIR/manifest.yml" <<'EOF'
version: 1
consumers:
  - name: with_seq_multi
    repo: example-org/with-seq-multi
    visibility: public
    facts:
      frameworks: [react, typescript]
      node_version: "20"
  - name: with_seq_single
    repo: example-org/with-seq-single
    visibility: public
    facts:
      frameworks: [astro]
  - name: with_empty_seq
    repo: example-org/with-empty-seq
    visibility: public
    facts:
      frameworks: []
  - name: with_no_facts
    repo: example-org/with-no-facts
    visibility: public
  - name: with_322_facts
    repo: example-org/with-322-facts
    visibility: public
    facts:
      frameworks: [react]
      testing: vitest
      jsx_in_js: true
      react_compiler: false
paths: []
EOF

# Run the yq filter that mirrors export_consumer_facts's filter.
# KEEP IN SYNC with scripts/sync-to-downstream.sh's export_consumer_facts.
run_filter() {
  local consumer_name=$1
  MERGEPATH_CONSUMER_NAME="$consumer_name" yq -r '
    env(MERGEPATH_CONSUMER_NAME) as $cn
    | .consumers[] | select(.name == $cn) | .facts // {} | to_entries[]
    | .key + "\t"
      + ((.value | select(tag == "!!seq") | join(" "))
         // (.value | tostring))
  ' "$WORKDIR/manifest.yml"
}

# Case 1: list-valued fact serializes as space-separated.
out=$(run_filter with_seq_multi)
expected="$(printf 'frameworks\treact typescript\nnode_version\t20')"
if [ "$out" = "$expected" ]; then
  pass "Case 1: list + scalar facts extract correctly (multi-element seq)"
else
  fail "Case 1: expected:\n$expected\ngot:\n$out"
fi

# Case 2: single-element list serializes to a single word.
out=$(run_filter with_seq_single)
expected="$(printf 'frameworks\tastro')"
if [ "$out" = "$expected" ]; then
  pass "Case 2: single-element list serializes to one word"
else
  fail "Case 2: expected:\n$expected\ngot:\n$out"
fi

# Case 3: empty list — join("") yields empty string; key still present.
# This was the case that masked the original bug; both broken-yq and
# correct-yq produced the same empty-string output for swipewatch's
# `frameworks: []`. Regression test pins the CORRECT behavior so a
# future broken-syntax change is caught.
out=$(run_filter with_empty_seq)
expected="$(printf 'frameworks\t')"
if [ "$out" = "$expected" ]; then
  pass "Case 3: empty-list fact yields key with empty value (masked the original bug)"
else
  fail "Case 3: expected:\n[$expected]\ngot:\n[$out]"
fi

# Case 4: consumer with no facts block at all — filter yields nothing.
out=$(run_filter with_no_facts)
if [ -z "$out" ]; then
  pass "Case 4: consumer without facts block yields no output"
else
  fail "Case 4: expected empty output, got:\n$out"
fi

# Case 5: the lib MUST contain the documented select-fallback idiom.
# If a future contributor reverts to the `if then else end` form
# (which mikefarah/yq rejects), this assertion catches it before the
# broken syntax ships. The filter moved to manifest-fact-helpers.sh
# in #323; grep the lib, not the sync script.
if grep -q 'select(tag == "!!seq") | join(" ")' "$LIB"; then
  pass "Case 5: lib helper uses the select+// idiom (not the broken if/then/else form)"
else
  fail "Case 5: scripts/lib/manifest-fact-helpers.sh no longer uses the select+// idiom — this regression-guard expects 'select(tag == \"!!seq\") | join(\" \")' in the helper"
fi

# Case 6: explicit no-regression check — the lib must NOT contain
# the broken form `if (tag == "!!seq") then`. This is the literal
# substring that caused the bug.
if ! grep -qF 'if (tag == "!!seq") then' "$LIB"; then
  pass "Case 6: lib helper does not contain the broken yq if/then/else form"
else
  fail "Case 6: lib helper contains the broken 'if (tag == \"!!seq\") then ... else ... end' form — mikefarah/yq rejects this at the lexer"
fi

# Case 7 (#323): sync-to-downstream.sh MUST source the lib so the
# wiring is not silently lost in a future refactor. A missing source
# would re-introduce the duplication this extraction was meant to
# eliminate.
if grep -q 'source "$MERGEPATH_ROOT/scripts/lib/manifest-fact-helpers.sh"' "$SCRIPT"; then
  pass "Case 7: sync-to-downstream.sh sources the manifest-fact-helpers lib"
else
  fail "Case 7: sync-to-downstream.sh no longer sources scripts/lib/manifest-fact-helpers.sh — wiring lost"
fi

# Case 7 (mergepath#322): mixed seq + scalar + bool facts serialize
# correctly. The template lib's expressions for the #322 facts read:
#   `>>> if testing contains vitest`     → needs "vitest" string
#   `>>> if jsx_in_js`                   → needs non-empty value (e.g. "true")
#   `>>> if !react_compiler`             → needs treat-"false"-as-set
#     (which is what `_fact_value` does — set-but-empty is rare; set
#     to "false" is a non-empty value so `!react_compiler` evaluates
#     FALSE, suppressing the disable block as desired).
# The yq filter MUST emit one tab-separated row per fact, with bool
# values rendered as the strings "true" / "false" (not YAML-literal
# variants). Locks in the bool-serialization shape this depends on.
out=$(run_filter with_322_facts)
expected="$(printf 'frameworks\treact\ntesting\tvitest\njsx_in_js\ttrue\nreact_compiler\tfalse')"
if [ "$out" = "$expected" ]; then
  pass "Case 7 (#322): seq + scalar + bool facts serialize as expected (booleans → 'true'/'false' strings)"
else
  fail "Case 7 (#322): expected:\n$expected\ngot:\n$out"
fi

# Case 8 (#457): the helper must fail CLOSED on a manifest yq cannot
# parse. The earlier `while ... done < <(yq ...)` form masked yq's exit
# code (the loop's status is the last `read`, never yq's), so a malformed
# manifest exported no facts yet returned 0 — letting a verification
# caller proceed on empty/wrong MERGEPATH_FACT_* state. This case sources
# the lib and calls export_consumer_facts directly (the cases above only
# exercise a mirror of the filter) to assert non-zero rc AND no exports.
# shellcheck source=scripts/lib/manifest-fact-helpers.sh
source "$LIB"
cat > "$WORKDIR/malformed.yml" <<'EOF'
version: 1
consumers:
  - name: broken
    facts: {frameworks: [react, typescript
EOF
# Precondition: confirm the fixture is genuinely unparseable, else the
# case would pass vacuously if yq ever grows lenient about this input.
if yq -r '.' "$WORKDIR/malformed.yml" >/dev/null 2>&1; then
  fail "Case 8 precondition: fixture parsed cleanly; need a manifest yq rejects"
else
  facts_rc=0
  export_consumer_facts broken "$WORKDIR/malformed.yml" >/dev/null 2>&1 || facts_rc=$?
  leaked=$(env | awk -F= '/^MERGEPATH_FACT_/ {print $1}')
  if [ "$facts_rc" -ne 0 ] && [ -z "$leaked" ]; then
    pass "Case 8 (#457): export_consumer_facts fails closed (rc=$facts_rc) on unparseable manifest, no facts exported"
  else
    fail "Case 8 (#457): expected non-zero rc and no exports; got rc=$facts_rc, leaked=[$leaked]"
  fi
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_export_consumer_facts: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_export_consumer_facts: PASS ($TOTAL tests)"
exit 0
