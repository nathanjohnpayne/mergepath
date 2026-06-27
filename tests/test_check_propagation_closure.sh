#!/usr/bin/env bash
# tests/test_check_propagation_closure.sh
#
# Unit tests for scripts/ci/check_propagation_closure — the INVERSE of
# check_sync_manifest (the #519/#521 closure-completeness guard). The
# live invocation in PR CI smoke-tests the real tree; this file targets
# the detection logic against synthetic fixtures.
#
# Pattern matches tests/test_check_sync_manifest.sh — a fixture repo
# tree (manifest + a propagated scripts/ci/check_* file + the
# referenced files) written to a scratch dir, run via env override,
# assert on exit code + diagnostic substring.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_propagation_closure"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-propagation-closure-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Helper: build a fixture repo tree and run the check against it.
#
# Args:
#   $1 = manifest YAML content (written to manifest.yml; pass "" to omit
#        the manifest entirely, exercising the SKIP/FAIL marker logic)
#   $2 = newline-separated repo-relative paths to materialize (files for
#        non-trailing-slash entries, dirs for trailing-slash entries)
#   $3 = OPTIONAL: "no-marker" to SKIP creating scripts/sync-to-downstream.sh
#        (so a missing manifest reads as a consumer checkout). Default
#        creates the marker (mergepath checkout).
#
# Every fixture gets scripts/sync-to-downstream.sh (the mergepath marker)
# unless $3 == "no-marker", so the manifest-absent branch can be steered
# to either SKIP (consumer) or FAIL (mergepath).
run_with_fixture() {
  local manifest_content="$1" paths="$2" marker_mode="${3:-marker}"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"

  if [ "$marker_mode" != "no-marker" ]; then
    mkdir -p "$fix/scripts"
    : > "$fix/scripts/sync-to-downstream.sh"
  fi

  local manifest_arg=""
  if [ -n "$manifest_content" ]; then
    printf '%s' "$manifest_content" > "$fix/manifest.yml"
    manifest_arg="$fix/manifest.yml"
  else
    # Point at a path that does not exist so the check's manifest-absent
    # branch fires.
    manifest_arg="$fix/does-not-exist.yml"
  fi

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"

  MERGEPATH_MANIFEST_PATH="$manifest_arg" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

# Baseline manifest header. scripts/ci/ is a kit (so the fixture's
# check_* file is is_covered → scanned), and scripts/sync-to-downstream.sh
# is declared so the marker file doesn't get flagged as an undeclared
# self-... (it's the marker, not a scan target).
MIN_HEADER='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:
  - path: scripts/ci/
    type: kit
    consumers: all'

# A minimal propagated check_* body that references one test file. The
# referenced path is parameterized per-case by writing the file content
# inline in each case (run_with_fixture only touches empty stub files, so
# we overwrite the check_* stub with real content after).
#
# To keep run_with_fixture simple, each case writes its own
# scripts/ci/check_fixture file into the fixture AFTER the helper builds
# the tree. We therefore use a lower-level driver for the ref cases.
run_raw() {
  # $1 = manifest content, $2 = paths to materialize, $3 = check_* body,
  # $4 = relative path of the check file (default scripts/ci/check_fixture)
  local manifest_content="$1" paths="$2" check_body="$3"
  local check_rel="${4:-scripts/ci/check_fixture}"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  mkdir -p "$fix/scripts"
  : > "$fix/scripts/sync-to-downstream.sh"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  mkdir -p "$(dirname "$fix/$check_rel")"
  printf '%s' "$check_body" > "$fix/$check_rel"
  chmod +x "$fix/$check_rel"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

CHECK_BODY_REFS_TEST='#!/usr/bin/env bash
# fixture check that hard-runs a paired test
bash tests/test_widget.sh
'

# --- Case (a): undeclared, on-disk, propagated ref → FAIL naming it ---
# check_fixture (under the scripts/ci/ kit → propagated) references
# tests/test_widget.sh, which exists on disk but is NOT in the manifest.
MANIFEST_A="$MIN_HEADER"
PATHS_A="scripts/ci/
tests/test_widget.sh"
set +e
out=$(run_raw "$MANIFEST_A" "$PATHS_A" "$CHECK_BODY_REFS_TEST"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references 'tests/test_widget.sh' but that path is NOT covered"; then
  pass "Case (a): undeclared on-disk propagated ref fails closed naming the missing ref"
else
  fail "Case (a) unexpected (rc=$rc): $out"
fi

# --- Case (b): same ref but added to a requires: → PASS ---------------
MANIFEST_B='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - "tests/test_widget.sh"
  - path: tests/test_widget.sh
    type: canonical
    consumers: all'
PATHS_B="scripts/ci/
tests/test_widget.sh"
set +e
out=$(run_raw "$MANIFEST_B" "$PATHS_B" "$CHECK_BODY_REFS_TEST"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_propagation_closure: PASS"; then
  pass "Case (b): declaring the ref in requires: makes the check pass"
else
  fail "Case (b) unexpected (rc=$rc): $out"
fi

# --- Case (c): allow-listed ref (scripts/bootstrap/foo.sh) → PASS -----
# The fixture check references an allow-listed orchestrator path that is
# on disk but undeclared. The allow-list must exempt it.
CHECK_BODY_BOOTSTRAP='#!/usr/bin/env bash
bash scripts/bootstrap/foo.sh
'
MANIFEST_C="$MIN_HEADER"
PATHS_C="scripts/ci/
scripts/bootstrap/foo.sh"
set +e
out=$(run_raw "$MANIFEST_C" "$PATHS_C" "$CHECK_BODY_BOOTSTRAP"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_propagation_closure: PASS"; then
  pass "Case (c): allow-listed orchestrator ref (scripts/bootstrap/foo.sh) is exempt and passes"
else
  fail "Case (c) unexpected (rc=$rc): $out"
fi

# --- Case (d): consumer checkout (no manifest, no marker) → SKIP ------
set +e
out=$(run_with_fixture "" "" "no-marker"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_propagation_closure: SKIP"; then
  pass "Case (d): consumer checkout (no manifest, no marker) SKIPs with exit 0"
else
  fail "Case (d) unexpected (rc=$rc): $out"
fi

# --- Case (e): manifest absent but marker present → FAIL (mergepath) --
# Guards against a blanket SKIP fail-open: a deleted/renamed manifest in
# a mergepath checkout (marker present) must FAIL.
set +e
out=$(run_with_fixture "" "" "marker"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "manifest must not be deleted/renamed"; then
  pass "Case (e): manifest-absent + marker-present (mergepath) fails closed"
else
  fail "Case (e) unexpected (rc=$rc): $out"
fi

# --- Case (f): undeclared ref that does NOT exist on disk → PASS ------
# A reference to a path that is not a real file (fixture string, doc
# example, assertion literal) is not a propagation dependency and must
# NOT be flagged.
CHECK_BODY_GHOST='#!/usr/bin/env bash
# This is a doc example, not a real dependency:
#   bash scripts/cinema/ghost.sh
echo "ok"
'
MANIFEST_F="$MIN_HEADER"
PATHS_F="scripts/ci/"
set +e
out=$(run_raw "$MANIFEST_F" "$PATHS_F" "$CHECK_BODY_GHOST"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_propagation_closure: PASS"; then
  pass "Case (f): undeclared ref that does not exist on disk is not flagged (exists-on-disk filter)"
else
  fail "Case (f) unexpected (rc=$rc): $out"
fi

# --- Case (g): self-reference is skipped, not flagged -----------------
# A propagated check that names its OWN .sh path must not flag itself:
# the self-ref skip (`[ "$ref" = "$rel" ] && continue`) fires before the
# coverage test. The body references its own rel path WITH a .sh
# extension so the extractor actually emits it as a candidate — an
# extensionless name is never emitted by the scripts/*.{sh,cjs,js}
# matcher, so the earlier fixture exercised nothing. The scripts/ci/ kit
# covers the file, so it is scanned and the self-ref branch is hit.
# (The skip is belt-and-suspenders: a scan file is always is_covered, so
# its self-ref would be covered anyway — but we want the branch
# exercised and guarded against a future matcher that emits a file's own
# path.)
CHECK_BODY_SELF='#!/usr/bin/env bash
# scripts/ci/check_selfref.sh enumerates ... (names its own path)
echo "scripts/ci/check_selfref.sh"
'
MANIFEST_G="$MIN_HEADER"
PATHS_G="scripts/ci/"
set +e
out=$(run_raw "$MANIFEST_G" "$PATHS_G" "$CHECK_BODY_SELF" "scripts/ci/check_selfref.sh"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_propagation_closure: PASS"; then
  pass "Case (g): a propagated check naming its own .sh path is self-ref-skipped (no false positive)"
else
  fail "Case (g) unexpected (rc=$rc): $out"
fi

# --- Case (h): a NON-propagated check_* (not under a kit) is NOT ------
# scanned. If check_fixture is NOT covered by the manifest, its
# undeclared on-disk ref must not be flagged (only propagated files are
# scanned — an unpropagated check can't leak a dependency to a consumer).
MANIFEST_H='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:
  - path: scripts/op-preflight.sh
    type: canonical
    consumers: all'
# No scripts/ci/ kit → check_fixture is not covered → not scanned.
PATHS_H="scripts/op-preflight.sh
tests/test_widget.sh"
set +e
out=$(run_raw "$MANIFEST_H" "$PATHS_H" "$CHECK_BODY_REFS_TEST"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_propagation_closure: PASS"; then
  pass "Case (h): a non-propagated check_* is not scanned (no false positive on its refs)"
else
  fail "Case (h) unexpected (rc=$rc): $out"
fi

# --- Case (i): an EXACT-manifest workflow with an undeclared on-disk --
# script ref → FAIL. Workflows are scanned when they are exact manifest
# entries (canonical propagation).
WORKFLOW_BODY='name: fixture
on: [push]
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/helper.sh
'
MANIFEST_I='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:
  - path: .github/workflows/fixture.yml
    type: canonical
    consumers: all'
PATHS_I=".github/workflows/fixture.yml
scripts/helper.sh"
# Write the workflow as the "check body" at the workflow path.
set +e
out=$(run_raw "$MANIFEST_I" "$PATHS_I" "$WORKFLOW_BODY" ".github/workflows/fixture.yml"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references 'scripts/helper.sh' but that path is NOT covered"; then
  pass "Case (i): exact-manifest workflow with undeclared on-disk script ref fails closed"
else
  fail "Case (i) unexpected (rc=$rc): $out"
fi

# --- Case (j): a propagated workflow referencing an UNDECLARED ---------
# scripts/workflow/ helper must FAIL. The previously-broad
# `scripts/workflow/*` allow-list masked exactly this gap
# (nathanpayne-codex Phase-4b finding on #543): scripts/workflow/ is a
# kit, so a helper that genuinely travels is covered by is_covered; an
# undeclared one is the closure gap this check exists to catch.
WORKFLOW_BODY_J='name: fixture
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/workflow/parse_policy_list.sh .github/review-policy.yml available_reviewers
'
MANIFEST_J='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:
  - path: .github/workflows/pr-review-policy.yml
    type: canonical
    consumers: all'
PATHS_J=".github/workflows/pr-review-policy.yml
scripts/workflow/parse_policy_list.sh"
set +e
out=$(run_raw "$MANIFEST_J" "$PATHS_J" "$WORKFLOW_BODY_J" ".github/workflows/pr-review-policy.yml"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references 'scripts/workflow/parse_policy_list.sh' but that path is NOT covered"; then
  pass "Case (j): undeclared scripts/workflow/ helper ref in a propagated workflow fails closed (#543)"
else
  fail "Case (j) unexpected (rc=$rc): $out"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_propagation_closure: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_propagation_closure: PASS ($TOTAL tests)"
exit 0
