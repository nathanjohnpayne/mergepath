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

# --- identity/hub-only-doc denylist (#743) --------------------------
# A per-repo-owned identity doc or hub-only doc must never be a verbatim
# canonical/kit manifest entry — directly, via dest:, or inside a kit
# dir. templated is the one exempt escape hatch.

# Case 26: canonical BRAND.md → FAIL citing #743.
MANIFEST_ID_CANON="$MIN_HEADER
  - path: BRAND.md
    type: canonical
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_CANON" "BRAND.md"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "'BRAND.md' is a per-repo-owned identity/hub-only doc" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 26: canonical identity doc (BRAND.md) fails closed citing #743"
else
  fail "Case 26 unexpected (rc=$rc): $out"
fi

# Case 27: kit dir CONTAINING a denied doc → FAIL (kit-contains).
MANIFEST_ID_KIT="$MIN_HEADER
  - path: docs/agents/
    type: kit
    consumers: all
"
PATHS_ID_KIT="docs/agents/
docs/agents/repository-overview.md"
set +e
out=$(run_with_fixture "$MANIFEST_ID_KIT" "$PATHS_ID_KIT"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "'docs/agents/repository-overview.md' is a per-repo-owned identity/hub-only doc" && \
   echo "$out" | grep -q "kit-contains" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 27: kit dir containing an identity doc fails closed (kit-contains, #743)"
else
  fail "Case 27 unexpected (rc=$rc): $out"
fi

# Case 28: templated dest onto a denied doc → PASS (escape hatch).
MANIFEST_ID_TPL="$MIN_HEADER
  - path: examples/brand.md
    source: examples/brand.md
    dest: BRAND.md
    type: templated
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_TPL" "examples/brand.md"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 28: templated render onto an identity doc is exempt (escape hatch)"
else
  fail "Case 28 unexpected (rc=$rc): $out"
fi

# Case 29: canonical entry that REMAPS its dest onto a denied doc → FAIL
# (direct match on the effective dest, not the source path).
MANIFEST_ID_DEST="$MIN_HEADER
  - path: docs/brand-source.md
    dest: BRAND.md
    type: canonical
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_DEST" "docs/brand-source.md"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "'BRAND.md' is a per-repo-owned identity/hub-only doc" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 29: canonical dest remapped onto an identity doc fails closed (#743)"
else
  fail "Case 29 unexpected (rc=$rc): $out"
fi

# --- denylist bypass hardening (#745 Codex P2 ×3) -------------------

# Case 30: "./BRAND.md" spelling must not slip past the raw compare —
# normalization folds it to BRAND.md → FAIL.
MANIFEST_ID_DOTSLASH="$MIN_HEADER
  - path: ./BRAND.md
    type: canonical
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_DOTSLASH" "BRAND.md"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "'BRAND.md' is a per-repo-owned identity/hub-only doc" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 30: './BRAND.md' spelling normalized + fails closed (#745)"
else
  fail "Case 30 unexpected (rc=$rc): $out"
fi

# Case 31: a templated entry whose SOURCE is the denied doc itself
# (path: BRAND.md, no dest → renders .dest//.path = BRAND.md from
# mergepath's own BRAND.md) must FAIL — it is not the escape hatch.
MANIFEST_ID_TPL_SRC="$MIN_HEADER
  - path: BRAND.md
    type: templated
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_TPL_SRC" "BRAND.md"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "templated entry uses the identity/hub-only doc 'BRAND.md' as its source" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 31: templated-from-the-identity-doc-itself fails closed (#745)"
else
  fail "Case 31 unexpected (rc=$rc): $out"
fi

# Case 32: a repo-root kit (path: .) mirrors every tracked file, so it
# carries every denied doc → FAIL (repo-root-kit).
MANIFEST_ID_ROOTKIT="$MIN_HEADER
  - path: .
    type: kit
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_ROOTKIT" "."); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "repo-root-kit" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 32: repo-root kit (path: .) fails closed as containing every denied doc (#745)"
else
  fail "Case 32 unexpected (rc=$rc): $out"
fi

# Case 33: a CANONICAL entry whose explicit `source:` is a denied identity
# doc, with an innocuous path/dest, must FAIL (#763). The denylist compared
# only norm_path/norm_dest, so this verbatim-mirrored BRAND.md into every
# consumer under a harmless-looking destination.
MANIFEST_ID_CANON_SRC="$MIN_HEADER
  - path: docs/brand-mirror.md
    source: BRAND.md
    type: canonical
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_CANON_SRC" "$(printf 'docs/brand-mirror.md\nBRAND.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "BRAND.md" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 33: canonical entry sourced FROM an identity doc fails closed (#763)"
else
  fail "Case 33 unexpected (rc=$rc): $out"
fi

# Case 34: same for a KIT entry whose source DIRECTORY contains a denied doc.
# A file source (source: BRAND.md) would trip the later -d validation anyway,
# so the meaningful kit case is a directory that CONTAINS the denied doc — the
# containment branch, not the equality branch (#763).
MANIFEST_ID_KIT_SRC="$MIN_HEADER
  - path: docs/mirrored/
    source: .
    type: kit
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_ID_KIT_SRC" "$(printf 'docs/mirrored/\nBRAND.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "repo-root-kit" && \
   echo "$out" | grep -q "#743"; then
  pass "Case 34: kit whose source DIRECTORY contains an identity doc fails closed (#763)"
else
  fail "Case 34 unexpected (rc=$rc): $out"
fi

# Case 35: CONTROL — a canonical entry with a non-denied explicit source must
# still PASS, so Cases 33/34 are not just "any source: fails".
MANIFEST_OK_SRC="$MIN_HEADER
  - path: docs/ordinary-mirror.md
    source: docs/ordinary.md
    type: canonical
    consumers: all
"
set +e
out=$(run_with_fixture "$MANIFEST_OK_SRC" "$(printf 'docs/ordinary-mirror.md\ndocs/ordinary.md')"); rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 35: canonical entry with a non-denied source still passes (#763 control)"
else
  fail "Case 35 unexpected (rc=$rc): $out"
fi

# --- canonical agent-docs propagation contract (#770/#771) -----------
#
# Unlike every case above, these two read the LIVE manifest and the LIVE
# docs. They guard a contract no fixture can express: that the canonical
# `docs/agents/*.md` convention docs are actually declared, and that each
# one stays TRUE verbatim on a consumer.
#
# Gated on POSITIVE proof that this is a mergepath checkout — the live
# manifest AND the never-propagated sync engine both present, the same
# marker pair check_sync_manifest itself uses. Anything else skips: the
# suite is hub-only (it is on check_propagation_closure's ALLOW_LIST),
# so a checkout without both markers cannot satisfy these assertions and
# must not be failed for it.
LIVE_MANIFEST="$ROOT/.mergepath-sync.yml"
LIVE_MARKER="$ROOT/scripts/sync-to-downstream.sh"
if [ -f "$LIVE_MANIFEST" ] && [ -f "$LIVE_MARKER" ]; then

  # Case 36: docs/agents/decision-records.md is declared canonical/all.
  # The decision-records convention (#770 change-level "## Path taken"
  # records + #771 issue-level decision callouts) is only a fleet
  # convention if it actually travels; a silent manifest drop would
  # leave mergepath following a rule no consumer ever receives.
  DR_PATH="docs/agents/decision-records.md"
  set +e
  dr_rows=$(yq -r "
    .paths[]
    | select(.path == \"$DR_PATH\")
    | (.type // \"null\") + \"|\" + (.consumers | (select(tag == \"!!str\") // (join(\",\"))) | tostring)
  " "$LIVE_MANIFEST"); rc=$?
  set -e
  if [ "$rc" = "0" ] && [ "$dr_rows" = "canonical|all" ]; then
    pass "Case 36: live manifest declares $DR_PATH canonical/all (#770/#771)"
  else
    fail "Case 36: expected 'canonical|all' for $DR_PATH, got (rc=$rc) '$dr_rows'"
  fi

  # Case 37: every canonical docs/agents/*.md entry is consumer-truthful.
  #
  # A canonical doc is copied VERBATIM, so a sentence that is true on
  # mergepath and false downstream ships as a false claim to every
  # consumer — the #744/#746 trap. Two mechanical tells:
  #
  #   (a) a bare `#NN` issue reference. GitHub resolves it against the
  #       repo it is rendered in, so on a consumer it silently points at
  #       that repo's own issue #NN. The cross-repo `owner/repo#NN` form
  #       (already used in REVIEW_POLICY.md and bootstrap-runbook.md) and
  #       full URLs are unambiguous everywhere; the pattern below
  #       deliberately does not match them, nor `#issuecomment-<id>`.
  #   (b) a reference to hub-only machinery — the propagation manifest,
  #       the sync engine, the wave audit, the bootstrap seeders, the
  #       weekly sweep, or the three hub-only machinery docs. None of
  #       these exist in a consumer checkout, so naming them as
  #       something the reader can run or read is false there.
  BARE_ISSUE_RE='(^|[^A-Za-z0-9_/-])#[0-9]+'
  HUB_ONLY_RE='\.mergepath-sync\.yml|sync-to-downstream\.sh|wave-audit\.sh|scripts/bootstrap/|sweep-unresolved-feedback|docs/agents/(bootstrap-runbook|propagation-ordering|templated-propagation)\.md'

  # Tell (a) scans PROSE ONLY. `#<digits>` is not an issue reference
  # inside a fenced code block (a CSS hex colour `#336699`, a literal in
  # a shell example), inside an inline code span, or in a markdown
  # in-page anchor target — `](#1-post-a-structured-decision-comment)`,
  # which is what a table of contents over this doc's own numbered
  # headings would emit. Blanking those out keeps the guard from
  # failing a required check with the misleading "bare issue reference"
  # diagnostic. One output line per input line, so `grep -n` still
  # reports the true line number.
  #
  # Deliberately NOT applied to tell (b): "run `wave-audit.sh`" is false
  # downstream wherever it appears, including inside a fenced example,
  # so the hub-only scan reads the raw file.
  #
  # Fence tracking follows CommonMark, the same delimiter rules the
  # fence-aware section scan in scripts/audit-canonical-mirrors.sh
  # applies. A naive unconditional toggle is not merely imprecise
  # here, it is a BYPASS: a four-backtick fence
  # wrapping a literal ``` line (the standard way to show a fence inside
  # a fence, which a doc that prescribes markdown formats will reach
  # for) has its content line close the fence and its real closing
  # delimiter open a new one. Every line after that is blanked as
  # "fence", so a bare #NN later in the file is never scanned and tell
  # (a) silently passes a doc it should fail. Three rules prevent that:
  #
  #   * at most THREE spaces of indent before a delimiter — at four or
  #     more columns the line is indented CODE, not a delimiter, and a
  #     tab already advances past the limit;
  #   * a fence closes only on a run of the SAME character at least as
  #     LONG as the opening run, so ``` cannot close ````;
  #   * a closing fence carries no info string, so a literal ```bash
  #     shown inside an open block is content, not the closer.
  #
  # Inline code spans are matched by delimiter RUN LENGTH for the same
  # reason fences are, but note the closing rule DIFFERS by design and
  # the two must not be "unified": a fence closes on a run at least as
  # long as the opener (>= fence_len, above), whereas a code span
  # closes only on a run of EXACTLY the opening length. That is
  # CommonMark, and it is what lets ``a`b`` hold a lone backtick.
  #
  # A naive gsub(/`[^`]*`/) instead matches the two OPENING backticks
  # of a ``#NN`` span as an empty single-backtick span, deletes them,
  # and leaves the bare #NN exposed to BARE_ISSUE_RE — a FALSE
  # POSITIVE that fails a required check on a doc whose #NN is code,
  # not an issue reference. That form is reachable, not theoretical: a
  # doc reaches for a multi-backtick span exactly when the span's
  # content itself holds a backtick, which a doc prescribing markdown
  # formats does.
  #
  # An opening run with no equal-length closer is NOT a span — it stays
  # literal, exactly as CommonMark renders it, so prose after it is
  # still scanned rather than being swallowed to end of line.
  #
  # Every branch prints exactly one line per input line, preserving the
  # `grep -n` line numbering the diagnostics depend on.
  md_prose_only() {
    awk '
      {
        line = $0
        indent = line
        sub(/[^ \t].*$/, "", indent)
        rest = substr(line, length(indent) + 1)

        is_delim = 0
        if (length(indent) < 4 && index(indent, "\t") == 0) {
          ch = substr(rest, 1, 1)
          if (ch == "`" || ch == "~") {
            run = 0
            while (substr(rest, run + 1, 1) == ch) run++
            if (run >= 3) is_delim = 1
          }
        }

        if (is_delim) {
          if (!fence) {
            fence = 1; fence_char = ch; fence_len = run
          } else if (ch == fence_char && run >= fence_len &&
                     substr(rest, run + 1) !~ /[^ \t]/) {
            fence = 0; fence_char = ""; fence_len = 0
          }
          print ""; next
        }
        if (fence) { print ""; next }

        line = strip_code_spans(line)
        gsub(/\]\(#[^)]*\)/, "]()", line)
        print line
      }

      # Remove inline code spans, matching opening and closing backtick
      # runs by LENGTH (CommonMark). An opening run with no closing run
      # of equal length is not a span at all — it stays as literal
      # text, which is what CommonMark renders.
      function strip_code_spans(s,   out, i, n, c, run, j, r2, found) {
        out = ""
        i = 1
        n = length(s)
        while (i <= n) {
          c = substr(s, i, 1)
          if (c != "`") { out = out c; i++; continue }
          run = 0
          while (i + run <= n && substr(s, i + run, 1) == "`") run++
          j = i + run
          found = 0
          while (j <= n) {
            if (substr(s, j, 1) == "`") {
              r2 = 0
              while (j + r2 <= n && substr(s, j + r2, 1) == "`") r2++
              if (r2 == run) { found = 1; break }
              j += r2
            } else {
              j++
            }
          }
          if (found) {
            i = j + run
          } else {
            out = out substr(s, i, run)
            i += run
          }
        }
        return out
      }
    ' "$1"
  }

  set +e
  canon_docs=$(yq -r '.paths[] | select(.type == "canonical") | .path' "$LIVE_MANIFEST" \
    | grep -E '^docs/agents/.*\.md$'); rc=$?
  set -e
  docs_bad=""
  docs_seen=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    docs_seen=$((docs_seen + 1))
    if [ ! -f "$ROOT/$d" ]; then
      docs_bad="$docs_bad
  $d: declared canonical but missing on disk"
      continue
    fi
    prose=$(md_prose_only "$ROOT/$d")
    if hits=$(printf '%s\n' "$prose" | grep -nE "$BARE_ISSUE_RE"); then
      docs_bad="$docs_bad
  $d: bare issue reference (use owner/repo#NN or a full URL):
$hits"
    fi
    if hits=$(grep -nE "$HUB_ONLY_RE" "$ROOT/$d"); then
      docs_bad="$docs_bad
  $d: names hub-only machinery a consumer does not have:
$hits"
    fi
  done <<< "$canon_docs"
  if [ "$rc" != "0" ] || [ "$docs_seen" -eq 0 ]; then
    fail "Case 37: no canonical docs/agents/*.md entries found in the live manifest (rc=$rc)"
  elif [ -n "$docs_bad" ]; then
    fail "Case 37: canonical agent doc(s) not true verbatim downstream (#744/#746):$docs_bad"
  else
    pass "Case 37: all $docs_seen canonical docs/agents/*.md entries are consumer-truthful"
  fi

  # Case 38: self-test of the tell-(a) predicate, in BOTH directions.
  #
  # Case 37 reads the live tree, where every canonical agent doc happens
  # to be clean — so on its own it never exercises the predicate's
  # positive branch, and never proves the negative branch either. This
  # fixture pins both: one real bare ref in prose must be flagged, and
  # the four forms that legitimately carry `#<digits>` must not be.
  FP_DOC="$WORKDIR/consumer-truth-fixture.md"
  cat > "$FP_DOC" <<'FIXTURE_EOF'
# Doc

## Contents
- [Post a structured decision comment](#1-post-a-structured-decision-comment)

Cross-repo owner/repo#702 and permalink #issuecomment-5104563868 are fine.

```css
a { color: #336699; }
```

An inline hex `#1a2b3c` is not an issue reference.

But a bare #740 in prose is.
FIXTURE_EOF
  set +e
  fp_hits=$(md_prose_only "$FP_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  if [ "$fp_hits" = "14," ]; then
    pass "Case 38: bare-issue predicate flags the prose ref on line 14 only (not anchors, fences, or code spans)"
  else
    fail "Case 38: expected only line 14 flagged, got '$fp_hits'"
  fi

  # Case 39: fence tracking is CommonMark-compatible, not a naive toggle.
  #
  # Case 38's fixture only ever opens and closes plain ``` fences, so it
  # passes under an unconditional toggle too and proves nothing about
  # the delimiter rules. This fixture pins all three rules AND the
  # bypass they prevent. Under the naive toggle this replaced, the
  # ```bash and ``` and ~~~ lines nested inside the ````text block each
  # flip fence state, so #111 and #444 leak into prose as false
  # positives; the run of flips leaves state INVERTED at the
  # four-space-indented ``` on line 18, which then opens a fence that
  # never closes and swallows the rest of the file — so the real bare
  # #333 on line 20 goes unscanned and tell (a) passes a doc it must
  # fail. Correct behavior: line 20 is the only hit.
  FENCE_DOC="$WORKDIR/consumer-truth-fences.md"
  cat > "$FENCE_DOC" <<'FENCE_EOF'
# Doc

````text
```bash
echo "#111 not a ref"
```
~~~
still #444 inside the same block
~~~
````

~~~
A tilde fence holds #222 as content.
~~~

Four spaces of indent makes this code, not a delimiter:

    ```

But a bare #333 in prose is.
FENCE_EOF
  set +e
  fence_hits=$(md_prose_only "$FENCE_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  fence_lines=$(md_prose_only "$FENCE_DOC" | wc -l | tr -d ' ')
  raw_lines=$(wc -l < "$FENCE_DOC" | tr -d ' ')
  set -e
  if [ "$fence_hits" != "20," ]; then
    fail "Case 39: expected only line 20 flagged (nested/tilde/indented fences), got '$fence_hits'"
  elif [ "$fence_lines" != "$raw_lines" ]; then
    fail "Case 39: md_prose_only must emit one line per input line, got $fence_lines for $raw_lines"
  else
    pass "Case 39: fence tracking honors delimiter char, run length, info string, and the 3-space indent limit"
  fi

  # Case 40: inline code spans strip by delimiter RUN LENGTH.
  #
  # Cases 38-39 only ever use single-backtick spans, so they pass under
  # the naive gsub too and prove nothing about multi-backtick spans.
  # Under that gsub the ``#222`` line leaked a bare #222 into prose —
  # a FALSE POSITIVE failing a required check on a doc whose #NN is
  # code — and the ``a`b #333`` line was mangled into `a` + trailing
  # backtick rather than removed whole. The last line pins the other
  # direction: an unmatched run is literal per CommonMark, so the #555
  # beside it is real prose and MUST still be flagged.
  SPAN_DOC="$WORKDIR/consumer-truth-spans.md"
  cat > "$SPAN_DOC" <<'SPAN_EOF'
# Doc

A single-backtick span `#111` is code.

A double-backtick span ``#222`` is code.

A double-backtick span holding a backtick ``a`b #333`` is code.

A triple-backtick inline span ```#444``` is code.

An unmatched ``run stays literal, so this bare #555 is a real ref.
SPAN_EOF
  set +e
  span_hits=$(md_prose_only "$SPAN_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  span_lines=$(md_prose_only "$SPAN_DOC" | wc -l | tr -d ' ')
  span_raw=$(wc -l < "$SPAN_DOC" | tr -d ' ')
  set -e
  if [ "$span_hits" != "11," ]; then
    fail "Case 40: expected only line 11 flagged (multi-backtick spans are code), got '$span_hits'"
  elif [ "$span_lines" != "$span_raw" ]; then
    fail "Case 40: md_prose_only must emit one line per input line, got $span_lines for $span_raw"
  else
    pass "Case 40: inline code spans strip by delimiter run length (``#NN`` is code, unmatched run is prose)"
  fi

  # Case 41: the `## Path taken` carve-out is stated in a PROPAGATED doc.
  #
  # Two canonical docs travel to every consumer and, read together, used
  # to contradict each other: decision-records.md MANDATES a
  # `## Path taken` section in the PR body when a change reverses
  # direction, while the shared operating rules ban narrating the
  # session's path in a description — a ban whose own wording covers
  # descriptions, not just titles. The reconciliation is a carve-out
  # naming that section explicitly, and it only helps a consumer if it
  # rides along with the halves it reconciles.
  #
  # docs/agents/operating-rules.md is per-repo-owned (see the
  # doc_ownership block) and carries its own copy of the same narration
  # rule, so a carve-out written only there reaches nobody: every
  # consumer would receive both halves of the contradiction and none of
  # the resolution. This case pins the carve-out to the canonical file
  # AND to the section it qualifies, so a later edit cannot quietly move
  # it back into the un-propagated overlay
  # (nathanjohnpayne/mergepath#788).
  SOR_PATH="docs/agents/shared-operating-rules.md"
  NARRATION_HEADING="## PR and issue titles/descriptions: describe the work, not the session"
  set +e
  sor_rows=$(yq -r "
    .paths[]
    | select(.path == \"$SOR_PATH\")
    | (.type // \"null\") + \"|\" + (.consumers | (select(tag == \"!!str\") // (join(\",\"))) | tostring)
  " "$LIVE_MANIFEST"); rc=$?
  set -e
  if [ ! -f "$ROOT/$SOR_PATH" ]; then
    fail "Case 41: $SOR_PATH missing on disk"
  elif [ "$rc" != "0" ] || [ "$sor_rows" != "canonical|all" ]; then
    fail "Case 41: expected 'canonical|all' for $SOR_PATH, got (rc=$rc) '$sor_rows'"
  else
    # Extract the narration section only — heading line exclusive, up to
    # the next level-2 heading — so a mention anywhere else in the file
    # cannot satisfy the assertion.
    #
    # BOTH tokens are required, and the conjunction is the point: the
    # heading alone can be named in passing (a "see also" line), and the
    # doc path alone does not say which of its rules is exempt. A
    # section that carries only one of them has lost the carve-out even
    # though it still mentions its vocabulary.
    narration_sec=$(awk -v h="$NARRATION_HEADING" '
      index($0, h) == 1 { in_sec = 1; next }
      in_sec && /^## / { exit }
      in_sec { print }
    ' "$ROOT/$SOR_PATH")
    set +e
    carve_heading=$(printf '%s\n' "$narration_sec" | grep -cF '## Path taken')
    carve_doc=$(printf '%s\n' "$narration_sec" | grep -cF 'docs/agents/decision-records.md')
    set -e
    if [ -z "$narration_sec" ]; then
      fail "Case 41: $SOR_PATH has no '$NARRATION_HEADING' section"
    elif [ "${carve_heading:-0}" -lt 1 ] || [ "${carve_doc:-0}" -lt 1 ]; then
      fail "Case 41: $SOR_PATH § narration rule does not carve out '## Path taken' per docs/agents/decision-records.md (heading hits=${carve_heading:-0}, doc hits=${carve_doc:-0}) — the reconciliation would be unreachable by consumers (nathanjohnpayne/mergepath#788)"
    else
      pass "Case 41: the '## Path taken' narration carve-out is stated in the propagated shared rules"
    fi
  fi

  # Case 42: the carve-out is stated identically in both hub copies.
  #
  # The narration rule exists twice on the hub: once in the canonical
  # shared core (propagated to every consumer) and once in
  # docs/agents/operating-rules.md, the per-repo-owned LOCAL OVERLAY that
  # still carries its own copy of the same rule pending the #780 split.
  # The overlay is the copy a hub agent actually reads via the AGENTS.md
  # reading order, so a carve-out that lands in only one of them leaves
  # the other reading as a flat ban — which is the #788 contradiction
  # reintroduced one file over.
  #
  # Nothing propagates between the two: the overlay is per-repo-owned, so
  # sync-to-downstream.sh never rewrites it and no faithful-mirror check
  # compares it against the canonical. The copies are hand-mirrored, and
  # the overlay says so in prose ("a verbatim copy of the shared core's")
  # — a claim with no enforcement behind it until this case. Compare the
  # carve-out block byte-for-byte rather than probing for tokens, so that
  # narrowing the exemption in one file and not the other fails here
  # (nathanjohnpayne/mergepath#788).
  CARVE_MARKER="- One narration-shaped section is carved out by name:"
  SOR_DOC="$ROOT/docs/agents/shared-operating-rules.md"
  OVERLAY_DOC="$ROOT/docs/agents/operating-rules.md"
  # The block runs from the marker bullet to the blank line that ends the
  # list, so a later bullet added to the exemption is compared too.
  extract_carveout() {
    awk -v m="$CARVE_MARKER" '
      index($0, m) == 1 { in_blk = 1 }
      in_blk && $0 == "" { exit }
      in_blk { print }
    ' "$1"
  }
  set +e
  overlay_class=$(yq -r '
    .doc_ownership[]
    | select(.path == "docs/agents/operating-rules.md")
    | .class
  ' "$LIVE_MANIFEST"); overlay_rc=$?
  set -e
  if [ ! -f "$SOR_DOC" ] || [ ! -f "$OVERLAY_DOC" ]; then
    fail "Case 42: shared-operating-rules.md and/or operating-rules.md missing on disk"
  elif [ "$overlay_rc" != "0" ] || [ "$overlay_class" != "per-repo-owned" ]; then
    # If the overlay ever becomes canonical the hand-mirror premise is
    # gone and this case should be rewritten, not silently passed.
    fail "Case 42: expected docs/agents/operating-rules.md class 'per-repo-owned', got (rc=$overlay_rc) '$overlay_class'"
  else
    sor_carveout=$(extract_carveout "$SOR_DOC")
    overlay_carveout=$(extract_carveout "$OVERLAY_DOC")
    if [ -z "$sor_carveout" ]; then
      fail "Case 42: no '## Path taken' carve-out block in docs/agents/shared-operating-rules.md"
    elif [ -z "$overlay_carveout" ]; then
      fail "Case 42: docs/agents/operating-rules.md has no carve-out block — the hub overlay reads as a flat narration ban (nathanjohnpayne/mergepath#788)"
    elif [ "$sor_carveout" != "$overlay_carveout" ]; then
      fail "Case 42: the carve-out block differs between docs/agents/shared-operating-rules.md and the docs/agents/operating-rules.md overlay; they are hand-mirrored and must stay byte-identical (nathanjohnpayne/mergepath#788)"
    else
      pass "Case 42: the narration carve-out is byte-identical in the canonical shared rules and the hub overlay"
    fi
  fi

else
  echo "SKIP: Cases 36-42 need a mergepath checkout (live manifest + sync-to-downstream.sh)"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_sync_manifest: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_sync_manifest: PASS ($TOTAL tests)"
exit 0
