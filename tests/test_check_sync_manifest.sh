#!/usr/bin/env bash
# tests/test_check_sync_manifest.sh
#
# Unit tests for scripts/ci/check_sync_manifest — specifically the
# new `requires:` closure invariant added in #264. The pre-existing
# manifest-shape checks (consumer set, type set, etc.) are covered
# implicitly by running the check against the live .mergepath-sync.yml
# in PR CI; this file targets the new closure logic.
#
# Pattern matches tests/test_gh_pr_guard.sh — fixture manifests
# written to a scratch dir, run check_sync_manifest via env override,
# assert on exit code + diagnostic substring.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_sync_manifest"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-sync-manifest-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Helper: build a fixture repo tree (with stub files for every path
# referenced in the manifest) and run the check against it. Sets both
# MERGEPATH_MANIFEST_PATH and MERGEPATH_REPO_ROOT so the check probes
# the fixture instead of the live repo. The pre-existing path-
# existence check requires every canonical/templated path in the
# manifest to be a real file, so the helper touches each one in the
# fixture root before invoking the check.
#
# Args: $1 = manifest YAML content, $2 = newline-separated list of
# repo-relative paths to materialize (files for non-trailing-slash
# entries, dirs for trailing-slash kit entries).
run_with_fixture() {
  local manifest_content="$1" paths="$2"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

# --- Test fixture: baseline well-formed manifest --------------------
MIN_HEADER='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:'

# --- Case 1: requires: all satisfied by exact + kit-prefix coverage -
MANIFEST_SAT="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \"tests/test_kit_helper.sh\"
      - \"scripts/ci/fixtures/foo.json\"
  - path: tests/test_kit_helper.sh
    type: canonical
    consumers: all
"
PATHS_SAT="scripts/foo.sh
tests/test_foo.sh
tests/test_kit_helper.sh
scripts/ci/
scripts/ci/fixtures/foo.json"
set +e
out=$(run_with_fixture "$MANIFEST_SAT" "$PATHS_SAT"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 1: requires: satisfied by exact + kit-prefix coverage"
else
  fail "Case 1 unexpected (rc=$rc): $out"
fi

# --- Case 2: requires: pointing at an UNCOVERED path ----------------
MANIFEST_UNCOV="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires:
      - \"tests/missing.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_UNCOV="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_UNCOV" "$PATHS_UNCOV"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "requires 'tests/missing.sh' but that path is not covered"; then
  pass "Case 2: uncovered requires fails closed with named-path diagnostic"
else
  fail "Case 2 unexpected (rc=$rc): $out"
fi

# --- Case 3: entry WITHOUT requires: stays valid --------------------
MANIFEST_NOREQ="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_NOREQ="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_NOREQ" "$PATHS_NOREQ"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "PASS"; then
  pass "Case 3: missing requires: is valid (optional field)"
else
  fail "Case 3 unexpected (rc=$rc): $out"
fi

# --- Case 4: malformed requires: (scalar instead of sequence) ------
MANIFEST_MAL="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires: \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_MAL="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_MAL" "$PATHS_MAL"); rc=$?
set -e
# yq's `.requires[]` on a scalar errors OR splits per-char depending on
# version; either way the check must exit non-zero with FAIL output.
if [ "$rc" = "1" ] && echo "$out" | grep -q "FAIL"; then
  pass "Case 4: scalar requires: rejected (fails closed)"
else
  fail "Case 4 unexpected (rc=$rc): $out"
fi

# --- Case 5: kit-prefix boundary — adjacent dir does NOT count -----
# `scripts/ci/foo` should be covered by `scripts/ci/` kit, but
# `scripts/cinema/foo` must NOT be covered by `scripts/ci/` (the prefix
# match is slash-bounded).
MANIFEST_BOUND="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires:
      - \"scripts/cinema/foo.sh\"
  - path: scripts/ci/
    type: kit
    consumers: all
"
PATHS_BOUND="scripts/foo.sh
scripts/ci/"
set +e
out=$(run_with_fixture "$MANIFEST_BOUND" "$PATHS_BOUND"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "requires 'scripts/cinema/foo.sh' but that path is not covered"; then
  pass "Case 5: kit-prefix is slash-bounded (scripts/ci/ does NOT cover scripts/cinema/)"
else
  fail "Case 5 unexpected (rc=$rc): $out"
fi

# --- Case 6: consumer-scope-aware closure (#264 r2) ----------------
#
# nathanpayne-codex Phase 4b r1 on PR #294: the original closure
# check verified that a required path was IN the manifest but did
# NOT verify that the required path's `consumers:` covered the
# requirer's `consumers:`. If a kit propagates to `consumers: all`
# but a `requires:` entry points at a path with `consumers:
# [matchline]`, the other consumers still miss the dependency at
# lint time.

# Need at least two consumers to express a non-universal subset.
MULTI_HEADER='version: 1
consumers:
  - name: matchline
    repo: org/matchline
    visibility: public
  - name: swipewatch
    repo: org/swipewatch
    visibility: public
paths:'

MANIFEST_SCOPE_GAP="$MULTI_HEADER
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers:
      - matchline
"
PATHS_SCOPE_GAP="scripts/ci/
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_SCOPE_GAP" "$PATHS_SCOPE_GAP"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "does NOT cover the requirer" && \
   echo "$out" | grep -qE "requirer is consumers: all|matchline"; then
  pass "Case 6: requires: with narrower consumer scope fails closed (all → matchline gap)"
else
  fail "Case 6 unexpected (rc=$rc): $out"
fi

# Case 6b: explicit-list requirer with strict-subset required.
# Both are explicit lists; one consumer is missing from required.
MANIFEST_NAMED_GAP="$MULTI_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers:
      - matchline
      - swipewatch
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers:
      - matchline
"
PATHS_NAMED_GAP="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_NAMED_GAP" "$PATHS_NAMED_GAP"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "does NOT cover" && \
   echo "$out" | grep -q "swipewatch"; then
  pass "Case 6b: named-consumer-list requires: gap fails closed and names the missing consumer (swipewatch)"
else
  fail "Case 6b unexpected (rc=$rc): $out"
fi

# Case 7: same shape but required's consumers covers requirer's.
# Should PASS.
MANIFEST_SCOPE_OK="$MULTI_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers:
      - matchline
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers:
      - matchline
      - swipewatch
"
PATHS_SCOPE_OK="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_SCOPE_OK" "$PATHS_SCOPE_OK"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 7: requires: covered by superset consumer scope passes"
else
  fail "Case 7 unexpected (rc=$rc): $out"
fi

# Case 8: consumers: all → all (trivial universal coverage).
MANIFEST_ALL_ALL="$MIN_HEADER
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_ALL_ALL="scripts/ci/
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_ALL_ALL" "$PATHS_ALL_ALL"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 8: consumers: all → all trivially passes"
else
  fail "Case 8 unexpected (rc=$rc): $out"
fi

# NOTE: a "live manifest" smoke case is intentionally absent. The
# live invocation of check_sync_manifest in PR CI already smoke-tests
# the live manifest; invoking it from inside this fixture suite
# recurses through the new "run regression suite" call at the bottom
# of check_sync_manifest. Trust the CI invocation to do the smoke.

# --- Templated + source/dest + facts validation (PR following #313) --

# Case 9: templated with explicit source ≠ path + dest passes.
MANIFEST_TPL_OK="$MIN_HEADER
  - path: examples/eslint.config.js
    type: templated
    source: examples/eslint.config.js
    dest: eslint.config.js
    consumers: all
"
PATHS_TPL_OK="examples/eslint.config.js"
set +e
out=$(run_with_fixture "$MANIFEST_TPL_OK" "$PATHS_TPL_OK"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 9: templated with source/dest passes"
else
  fail "Case 9 unexpected (rc=$rc): $out"
fi

# Case 10: templated without dest emits WARN but passes.
MANIFEST_TPL_NODEST="$MIN_HEADER
  - path: examples/eslint.config.js
    type: templated
    consumers: all
"
PATHS_TPL_NODEST="examples/eslint.config.js"
set +e
out=$(run_with_fixture "$MANIFEST_TPL_NODEST" "$PATHS_TPL_NODEST"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "WARN: templated path" && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 10: templated without dest warns but passes"
else
  fail "Case 10 unexpected (rc=$rc): $out"
fi

# Case 11: absolute `dest:` is rejected.
MANIFEST_DEST_ABS="$MIN_HEADER
  - path: examples/x.js
    type: templated
    dest: /etc/passwd
    consumers: all
"
PATHS_DEST_ABS="examples/x.js"
set +e
out=$(run_with_fixture "$MANIFEST_DEST_ABS" "$PATHS_DEST_ABS"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "dest '/etc/passwd' that is absolute"; then
  pass "Case 11: absolute dest rejected"
else
  fail "Case 11 unexpected (rc=$rc): $out"
fi

# Case 12: dest with '..' segment is rejected.
MANIFEST_DEST_DOTDOT="$MIN_HEADER
  - path: examples/x.js
    type: templated
    dest: ../escape.js
    consumers: all
"
PATHS_DEST_DOTDOT="examples/x.js"
set +e
out=$(run_with_fixture "$MANIFEST_DEST_DOTDOT" "$PATHS_DEST_DOTDOT"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "containing a '..' segment"; then
  pass "Case 12: dest with '..' rejected"
else
  fail "Case 12 unexpected (rc=$rc): $out"
fi

# Case 13: source ≠ path triggers source existence check, fails on missing.
MANIFEST_SRC_MISSING="$MIN_HEADER
  - path: eslint.config.js
    type: templated
    source: examples/missing.js
    dest: eslint.config.js
    consumers: all
"
# Materialize path (existence requirement) but NOT source.
PATHS_SRC_MISSING="eslint.config.js"
set +e
out=$(run_with_fixture "$MANIFEST_SRC_MISSING" "$PATHS_SRC_MISSING"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "source 'examples/missing.js' must be a regular file for templated entries"; then
  pass "Case 13: source ≠ path with missing source rejected (templated: requires regular file)"
else
  fail "Case 13 unexpected (rc=$rc): $out"
fi

# Case 13b: templated source pointing at a DIRECTORY is rejected (a
# directory can't be a template). CodeRabbit Major on PR #316 caught
# this gap — the previous `-e` check would have accepted a directory.
MANIFEST_SRC_ISDIR="$MIN_HEADER
  - path: eslint.config.js
    type: templated
    source: examples/somedir
    dest: eslint.config.js
    consumers: all
"
PATHS_SRC_ISDIR="eslint.config.js
examples/somedir/"
set +e
out=$(run_with_fixture "$MANIFEST_SRC_ISDIR" "$PATHS_SRC_ISDIR"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "must be a regular file for templated entries"; then
  pass "Case 13b: templated source pointing at a directory rejected"
else
  fail "Case 13b unexpected (rc=$rc): $out"
fi

# Case 14: valid consumer facts (scalar + list) pass.
MANIFEST_FACTS_OK='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
    facts:
      frameworks: [react, typescript]
      node_version: "20"
      has_ts: yes
paths:
  - path: scripts/foo.sh
    type: canonical
    consumers: all
'
PATHS_FACTS_OK="scripts/foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_FACTS_OK" "$PATHS_FACTS_OK"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 14: valid consumer facts (scalar + list) pass"
else
  fail "Case 14 unexpected (rc=$rc): $out"
fi

# Case 15: facts key with uppercase rejected.
MANIFEST_FACTS_KEY_BAD='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
    facts:
      Frameworks: [react]
paths:
  - path: scripts/foo.sh
    type: canonical
    consumers: all
'
set +e
out=$(run_with_fixture "$MANIFEST_FACTS_KEY_BAD" "scripts/foo.sh"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "facts: key 'Frameworks' must match"; then
  pass "Case 15: facts key with uppercase rejected"
else
  fail "Case 15 unexpected (rc=$rc): $out"
fi

# Case 16: facts value as nested mapping rejected.
MANIFEST_FACTS_NESTED='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
    facts:
      framework_config:
        react: true
        ts: true
paths:
  - path: scripts/foo.sh
    type: canonical
    consumers: all
'
set +e
out=$(run_with_fixture "$MANIFEST_FACTS_NESTED" "scripts/foo.sh"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "unsupported value type '!!map'"; then
  pass "Case 16: facts value as nested mapping rejected"
else
  fail "Case 16 unexpected (rc=$rc): $out"
fi

# Case 17b: facts as a sequence rejected (must be a mapping).
# Codex Phase 4b CHANGES_REQUESTED on PR #316 by nathanpayne-codex
# caught this gap — `to_entries` on a sequence yields numeric-index
# keys that pass the [a-z0-9_-]+ charset check, so per-entry
# validation false-passed.
MANIFEST_FACTS_SEQ='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
    facts: [react, typescript]
paths:
  - path: scripts/foo.sh
    type: canonical
    consumers: all
'
set +e
out=$(run_with_fixture "$MANIFEST_FACTS_SEQ" "scripts/foo.sh"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "facts: must be a YAML mapping (got tag '!!seq')"; then
  pass "Case 17b: facts as sequence rejected"
else
  fail "Case 17b unexpected (rc=$rc): $out"
fi

# Case 18: explicit dest: "" on templated entry rejected. Same Codex
# Phase 4b finding — empty-string dest would pass through to
# materialize_templated_targets which then aborts with a less-clear
# error. Reject at validation. (Also exercises the IFS='|' field-
# stability fix, since with IFS=$'\t' the empty dest field would
# collapse and the validator would never see it as "" specifically.)
MANIFEST_DEST_EMPTY="$MIN_HEADER
  - path: examples/foo.js
    type: templated
    dest: \"\"
    consumers: all
"
PATHS_DEST_EMPTY="examples/foo.js"
set +e
out=$(run_with_fixture "$MANIFEST_DEST_EMPTY" "$PATHS_DEST_EMPTY"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q 'explicit dest: "" — dest must be non-empty when set'; then
  pass "Case 18: explicit empty dest: \"\" rejected"
else
  fail "Case 18 unexpected (rc=$rc): $out"
fi

# Case 18bis: .paths: [] (empty sequence) passes — yq emits no
# rows, the outer guard skips the loop, and validation completes
# without firing the new fail-closed has_path check on the
# bash-here-string-injected blank iteration. Codex Phase 4b P2 on
# PR #320 by nathanpayne-codex caught the regression from the
# original PR #320 patch where the guard was missing.
MANIFEST_EMPTY_PATHS='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths: []
'
set +e
out=$(run_with_fixture "$MANIFEST_EMPTY_PATHS" ""); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 18bis: empty .paths: [] passes (no false-positive from has_path check)"
else
  fail "Case 18bis unexpected (rc=$rc): $out"
fi

# Case 18c: .paths[] entry missing `path` field rejected (fail-closed,
# was silent-skip). CodeRabbit Major + Codex Phase 4b CHANGES_REQUESTED
# on Phase D consumer PRs both flagged the same gap.
MANIFEST_NO_PATH="$MIN_HEADER
  - type: canonical
    consumers: all
"
PATHS_NO_PATH="scripts/foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_NO_PATH" "$PATHS_NO_PATH"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has no 'path' field"; then
  pass "Case 18c: .paths[] entry without path field rejected (fail-closed)"
else
  fail "Case 18c unexpected (rc=$rc): $out"
fi

# Case 18d: .paths[] entry with explicit empty path: "" rejected.
MANIFEST_EMPTY_PATH="$MIN_HEADER
  - path: \"\"
    type: canonical
    consumers: all
"
PATHS_EMPTY_PATH="scripts/foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_EMPTY_PATH" "$PATHS_EMPTY_PATH"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q 'explicit path: ""'; then
  pass "Case 18d: .paths[] entry with explicit empty path rejected"
else
  fail "Case 18d unexpected (rc=$rc): $out"
fi

# Case 18b: explicit source: "" rejected (parallel to dest).
MANIFEST_SRC_EMPTY="$MIN_HEADER
  - path: examples/foo.js
    type: templated
    source: \"\"
    dest: eslint.config.js
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_SRC_EMPTY" "examples/foo.js"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q 'explicit source: "" — source must be non-empty when set'; then
  pass "Case 18b: explicit empty source: \"\" rejected"
else
  fail "Case 18b unexpected (rc=$rc): $out"
fi

# Case 17: consumer without facts: block still validates (facts is optional).
MANIFEST_NO_FACTS='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:
  - path: scripts/foo.sh
    type: canonical
    consumers: all
'
set +e
out=$(run_with_fixture "$MANIFEST_NO_FACTS" "scripts/foo.sh"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 17: consumer without facts: passes (facts is optional)"
else
  fail "Case 17 unexpected (rc=$rc): $out"
fi

# Case 19 (#467): a kit entry whose `source:` override points at a
# regular FILE is rejected — a kit mirrors a whole subtree, so its
# source-of-truth must be a directory. Symmetric to Case 13b
# (templated source pointing at a directory). The previous `-e` check
# accepted any FS entry, so a file slipped through.
MANIFEST_KIT_SRC_FILE="$MIN_HEADER
  - path: scripts/ci/
    type: kit
    source: scripts/notadir
    consumers: all
"
PATHS_KIT_SRC_FILE="scripts/ci/
scripts/notadir"
set +e
out=$(run_with_fixture "$MANIFEST_KIT_SRC_FILE" "$PATHS_KIT_SRC_FILE"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "must be a directory for kit entries"; then
  pass "Case 19: kit source override pointing at a regular file rejected"
else
  fail "Case 19 unexpected (rc=$rc): $out"
fi

# Case 20 (#467): consumer coverage is UNIONED across every covering
# entry, not taken from the first match. `scripts/ci/helper.sh` is
# covered by BOTH a narrow exact entry (consumers: [matchline]) AND the
# broad `scripts/ci/` kit (consumers: all). A requirer with
# consumers: all requires it. Effective coverage is the union (all), so
# the closure check must PASS. The pre-fix first-match logic returned
# the exact entry's narrow [matchline] scope and failed the subset
# check even though the kit propagates the file everywhere.
MANIFEST_UNION="$MULTI_HEADER
  - path: scripts/ci/
    type: kit
    consumers: all
  - path: scripts/ci/helper.sh
    type: canonical
    consumers:
      - matchline
  - path: scripts/main.sh
    type: canonical
    consumers: all
    requires:
      - \"scripts/ci/helper.sh\"
"
PATHS_UNION="scripts/ci/
scripts/ci/helper.sh
scripts/main.sh"
set +e
out=$(run_with_fixture "$MANIFEST_UNION" "$PATHS_UNION"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 20: union coverage (narrow exact + broad kit) satisfies an all-scoped requirer"
else
  fail "Case 20 unexpected (rc=$rc): $out"
fi

# --- repo_lint.yml wiring-propagation contract (#601) ----------------
#
# The mergepath-only assertion (step 8 in check_sync_manifest) is OFF
# for fixture-driven runs (all cases above) and opted back in here via
# MERGEPATH_ASSERT_REPO_LINT=1. Same fixture helper, extra env var.
run_with_fixture_assert_rl() {
  local manifest_content="$1" paths="$2"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" \
    MERGEPATH_ASSERT_REPO_LINT=1 bash "$CHECK" 2>&1
}

# Case 21: contract satisfied — repo_lint.yml canonical/all entry +
# scripts/ci/ kit requires: it (and it requires the kit back) → PASS.
MANIFEST_RL_OK="$MIN_HEADER
  - path: .github/workflows/repo_lint.yml
    type: canonical
    consumers: all
    requires:
      - \"scripts/ci/\"
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \".github/workflows/repo_lint.yml\"
"
PATHS_RL_OK=".github/workflows/repo_lint.yml
scripts/ci/"
set +e
out=$(run_with_fixture_assert_rl "$MANIFEST_RL_OK" "$PATHS_RL_OK"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 21: repo_lint.yml wiring contract satisfied passes (#601)"
else
  fail "Case 21 unexpected (rc=$rc): $out"
fi

# Case 22: manifest missing the repo_lint.yml canonical entry entirely
# (and the kit requires:) → FAIL with the #601 diagnostics.
MANIFEST_RL_MISSING="$MIN_HEADER
  - path: scripts/ci/
    type: kit
    consumers: all
"
PATHS_RL_MISSING="scripts/ci/"
set +e
out=$(run_with_fixture_assert_rl "$MANIFEST_RL_MISSING" "$PATHS_RL_MISSING"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "manifest has no entry for '.github/workflows/repo_lint.yml'" && \
   echo "$out" | grep -q "#601"; then
  pass "Case 22: missing repo_lint.yml canonical entry fails closed citing #601"
else
  fail "Case 22 unexpected (rc=$rc): $out"
fi

# Case 23: repo_lint.yml entry present (canonical, all) but the
# scripts/ci/ kit requires: does NOT include it → FAIL naming the kit
# requires gap.
MANIFEST_RL_NO_KIT_REQ="$MIN_HEADER
  - path: .github/workflows/repo_lint.yml
    type: canonical
    consumers: all
    requires:
      - \"scripts/ci/\"
  - path: scripts/ci/
    type: kit
    consumers: all
"
set +e
out=$(run_with_fixture_assert_rl "$MANIFEST_RL_NO_KIT_REQ" "$PATHS_RL_OK"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "kit entry's requires: must include '.github/workflows/repo_lint.yml'" && \
   echo "$out" | grep -q "#601"; then
  pass "Case 23: kit requires: missing repo_lint.yml fails closed citing #601"
else
  fail "Case 23 unexpected (rc=$rc): $out"
fi

# Case 24: repo_lint.yml entry present but with narrowed consumers →
# FAIL (must be consumers: all so the wiring contract is fleet-wide).
MANIFEST_RL_NARROW="$MIN_HEADER
  - path: .github/workflows/repo_lint.yml
    type: canonical
    consumers:
      - example
    requires:
      - \"scripts/ci/\"
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \".github/workflows/repo_lint.yml\"
"
set +e
out=$(run_with_fixture_assert_rl "$MANIFEST_RL_NARROW" "$PATHS_RL_OK"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "must be consumers: all" && \
   echo "$out" | grep -q "#601"; then
  pass "Case 24: narrowed repo_lint.yml consumers fails closed citing #601"
else
  fail "Case 24 unexpected (rc=$rc): $out"
fi

# Case 25: assertion stays OFF for fixture runs that do not opt in —
# the same entry-less manifest as Case 22 passes without
# MERGEPATH_ASSERT_REPO_LINT=1 (regression guard for the scoping, so
# the earlier fixture cases stay valid).
set +e
out=$(run_with_fixture "$MANIFEST_RL_MISSING" "$PATHS_RL_MISSING"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 25: #601 assertion scoped off for non-opted-in fixture runs"
else
  fail "Case 25 unexpected (rc=$rc): $out"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_sync_manifest: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_sync_manifest: PASS ($TOTAL tests)"
exit 0
