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
  #     shown inside an open block is content, not the closer;
  #   * a BACKTICK fence opener's info string may not itself contain a
  #     backtick (a TILDE fence's may). A line like ```js `x` is
  #     therefore not a delimiter at all, it is an ordinary paragraph
  #     line. Accepting it opened a fence that the doc never intended,
  #     and the mis-tracked state then ran both ways: prose after it was
  #     blanked (a real bare #NN goes unscanned) until the doc's NEXT
  #     genuine opener was consumed as the closer, at which point that
  #     block's real fenced content was scanned as prose — a false
  #     positive failing a required check on a #NN that is code.
  #
  # INDENTED code blocks are excluded too, on the same grounds as fenced
  # ones: `#NN` four columns in is code, not an issue reference. Two
  # CommonMark rules keep the exclusion from swinging into UNDER-
  # reporting, which would be the dangerous direction here — a bare ref
  # silently shipped to every consumer:
  #
  #   * an indented code block cannot interrupt a paragraph, so a
  #     wrapped prose line that happens to be indented is still prose;
  #   * the four columns are measured from the CONTENT indent of the
  #     innermost open list item, not from column zero, so the
  #     continuation paragraph of a `1. ` item — indented four spaces,
  #     three of which are the marker — stays prose and is still
  #     scanned. That measure is relative all the way down: a nested
  #     list marker deepens the container rather than tripping the code
  #     branch, so ordinary two-level indented nesting keeps its prose
  #     scanned, and a marker with nothing after it opens an empty item
  #     whose own prose is scanned the same way. Where the container is
  #     ambiguous the threshold is left HIGH, which errs toward
  #     scanning.
  #
  # Open containers must also CLOSE, or the relative measure stops being
  # a measure at all: once a document outdents back to an outer item the
  # stale inner threshold is too deep, and the outer item's indented code
  # block surfaces as prose — a required check failing on a `#NN` that is
  # code. Containers are therefore tracked as a stack and popped at block
  # boundaries, so identical markdown classifies identically wherever it
  # sits in the nesting. An EMPTY item closes on its own rule: CommonMark
  # lets a list item begin with at most one blank line, so a bare marker
  # followed by a blank ends the list and the base indent returns to the
  # ENCLOSING container — one level, not all the way to column zero.
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
        ind = visual_indent(indent)

        # Every four-column allowance in this program — the fence
        # delimiter here, the block quote marker, the leaf blocks and the
        # list marker below — is measured from the container the line is
        # actually INSIDE, which is not always the innermost OPEN one:
        # popping is deferred inside a paragraph, so a lazy continuation
        # line can sit left of a container that is still on the stack.
        # Measuring from that stale-deep container admits constructs
        # CommonMark does not see, because four or more columns past the
        # container the line is really in the text is indented-code
        # shaped. At a block boundary the pop loop below has already run,
        # so this is the same number `list_indent` holds.
        #
        # It is computed HERE, above the fence branch, because a fence
        # delimiter is bounded the same way and nothing between the two
        # points changes the stack. Bounding the delimiter by an absolute
        # `ind < 4` instead stops recognising fences the moment the
        # content indent of a list item reaches four: the ```bash opener
        # inside a `10. ` item is never seen, no fence is ever open, and
        # the whole body of the block is emitted as prose — a required
        # check failing on a `#NN` that is code, which is the false-
        # positive direction the relative measure exists to close
        # everywhere else.
        #
        # A fence CLOSER is bounded relative to the container the fence
        # was OPENED in, not to whatever container the closing line lands
        # in, which is what the test below enforces (#791 review).
        #
        # A fenced code block has no lazy continuation, so a non-blank
        # line left of the content indent of that container is not part of
        # the item at all: the item ends there and the unclosed fence ends
        # with it. `fence_base` records that content indent at OPEN time
        # because by the closing line the stack no longer holds it.
        #
        # Recomputing the allowance from the closing line instead reads an
        # OUTDENTED delimiter as the closer of the inner fence, and that
        # inverts the parity of every fence after it: the top-level fence
        # CommonMark opens on that line is scanned as prose, and the first
        # real prose after its closer is blanked with its `#NN` inside.
        # Leaving the fence open on the other outdenting shapes — a bare
        # prose line, a sibling marker, a delimiter whose info string bars
        # it from opening — swallows the rest of the file the same way.
        # Both are the UNDER-reporting direction, a bare ref shipped past a
        # required consumer-truthfulness check, which is the one direction
        # this parser must never take.
        #
        # A BLANK line is not such a boundary: a list item survives blank
        # lines, so only `rest != ""` closes anything here. The containers
        # the line outdented out of are popped here rather than by the pop
        # loop below, because a delimiter line returns before reaching it.
        if (fence && rest != "" && ind < fence_base) {
          fence = 0; fence_char = ""; fence_len = 0; fence_base = 0
          while (depth > 0 && ind < stack[depth]) depth--
          list_indent = 0
          if (depth > 0) list_indent = stack[depth]
        }

        container_base = 0
        base_depth = depth
        while (base_depth > 0 && stack[base_depth] > ind) base_depth--
        if (base_depth > 0) container_base = stack[base_depth]

        # An empty item is decided by the line AFTER the marker, so the
        # flag the marker branch sets is read here, one line later, and
        # cleared unconditionally: any non-blank line — prose, a fence, an
        # indented line, anything — means the item HAS content and stays
        # open. Only the blank-line branch below acts on it.
        opened_empty_item = empty_item
        empty_item = 0

        is_delim = 0
        if (ind < container_base + 4) {
          ch = substr(rest, 1, 1)
          if (ch == "`" || ch == "~") {
            run = 0
            while (substr(rest, run + 1, 1) == ch) run++
            if (run >= 3) is_delim = 1
          }
        }
        # A backtick fence OPENER may not carry a backtick in its info
        # string; such a line is a paragraph, not a delimiter. Closers
        # are already covered by the whitespace-only remainder rule
        # below, and a tilde opener may hold backticks.
        if (is_delim && !fence && ch == "`" &&
            index(substr(rest, run + 1), "`") > 0) {
          is_delim = 0
        }

        if (is_delim) {
          indented_code = 0
          para = 0
          if (!fence) {
            # A fence is not a lazy continuation either, so an OPENER
            # closes every container it is not indented into, here rather
            # than at the next block boundary — the pop loop below is
            # never reached on a delimiter line.
            #
            # Without this the container stays on the stack for the whole
            # block, and `container_base` on the CLOSING line is measured
            # from a container CommonMark has already ended. A four-space
            # delimiter inside a fence opened at column zero is then read
            # as its closer, when CommonMark allows a closer at most three
            # spaces past the container and reads that line as CONTENT.
            # The result is the same inverted parity the block above
            # exists to stop, reached from the opening end instead: the
            # rest of the fence body is scanned, and the first real prose
            # after the true closer is blanked with its `#NN` inside.
            # Popping here is what makes the `fence_base` recorded below
            # the container the fence is really in, so the two ends agree.
            while (depth > 0 && ind < stack[depth]) depth--
            list_indent = 0
            if (depth > 0) list_indent = stack[depth]
            fence = 1; fence_char = ch; fence_len = run
            fence_base = container_base
          } else if (ch == fence_char && run >= fence_len &&
                     substr(rest, run + 1) !~ /[^ \t]/) {
            fence = 0; fence_char = ""; fence_len = 0; fence_base = 0
          }
          print ""; next
        }
        if (fence) { para = 0; print ""; next }

        # A blank line closes an open paragraph but NOT an indented code
        # block: a blank inside one is part of the block.
        #
        # It DOES close an empty list item. Per CommonMark a list item may
        # begin with at most one blank line, so a marker with nothing after
        # it followed by a blank ends the list, and the base indent returns
        # to the enclosing container. Opening that item without ever
        # closing it leaves the threshold too deep, and the indented code
        # block that follows is emitted as prose — the same false-positive
        # direction the stack above exists to prevent, on the very
        # construct that introduced it.
        if (rest == "") {
          para = 0
          if (opened_empty_item && depth > 0) {
            depth--
            list_indent = 0
            if (depth > 0) list_indent = stack[depth]
          }
          print ""; next
        }

        if (indented_code) {
          if (ind >= indented_code_min) { print ""; next }
          indented_code = 0
        }

        # Open list containers, held as a STACK of content indents so the
        # code threshold is measured from the container the line is
        # actually INSIDE. `list_indent` is the innermost open one.
        #
        # Popping matters as much as pushing. Only ever deepening the
        # indent and resetting it at column zero leaves a stale INNER
        # threshold in force once a document outdents back to the outer
        # item, and an indented code block belonging to that outer item
        # — four columns past the OUTER content indent but short of the
        # inner one — is then emitted as prose. That is the false-
        # positive direction: a required check fails on a `#NN` that is
        # code. Identical markdown must classify identically wherever it
        # sits, so a line at a block boundary closes every container it
        # is no longer indented into, and a marker closes every
        # container deeper than itself before opening its own.
        #
        # Popping is confined to block boundaries because a LAZY
        # continuation line may sit left of the container it belongs to;
        # leaving the threshold high there errs toward scanning.
        if (!para) {
          while (depth > 0 && ind < stack[depth]) depth--
          list_indent = 0
          if (depth > 0) list_indent = stack[depth]
        }

        # A marker counts while it is within four columns of the CURRENT
        # container content indent — the same relative measure the code
        # threshold uses, so a nested marker deepens the container
        # instead of tripping the code branch. Gating on an absolute
        # `ind < 4` instead stops tracking at the first sub-list and
        # blanks its prose as code, which is the UNDER-reporting
        # direction: a bare ref shipped unflagged. At four or more
        # columns past the container the marker really is code, and
        # falls through to the branch below.
        #
        # A marker followed by nothing but blanks opens an EMPTY list
        # item, which is a container like any other; requiring
        # whitespace after every marker skips it and leaves the
        # threshold pinned to the OUTER item, so prose inside the empty
        # item is blanked as code and its bare refs go unflagged — the
        # UNDER-reporting direction again. CommonMark puts the content
        # indent of an empty item at the marker width plus one, no
        # matter how much blank space trails the marker, so the gap
        # after the marker is not counted in that case.
        #
        # The marker and the gap after it are measured separately rather
        # than in one pattern: an anchor inside a subexpression, as in
        # `([ \t]+|$)`, is implementation-defined in POSIX ERE and this
        # awk program has to behave the same under every awk CI runs on.
        # A marker with a non-blank hard against it (`-x`, `1.5`) is not
        # a list marker at all and leaves the container untouched.
        #
        # The gap is measured in COLUMNS, from where it starts. A tab is
        # not one column wide and is not four either — it advances to
        # the next four-column stop, so its width depends on the column
        # the marker leaves off at. Counting characters is the
        # UNDER-reporting direction here, because it reports the content
        # indent as SHALLOWER than CommonMark renders it and drags the
        # code threshold down with it; prose four or more columns past
        # the phantom indent, but inside the item as CommonMark reads
        # it, is blanked and its bare refs ship unflagged. Markers hold
        # no tabs themselves, so the gap starts at `ind + marker_width`.
        #
        # CommonMark counts at most four columns of that gap: five or
        # more means the item STARTS with indented code, and the content
        # indent is the marker width plus one. The cap is not cosmetic.
        # An over-deep container is not the harmless over-scan it looks
        # like, because the pop loop above compares against it: a later
        # line that CommonMark still reads as inside the item sits left
        # of the phantom indent, closes the container, and is then
        # measured against the DOCUMENT — four columns in is indented
        # code there, so it is blanked. Measuring in columns without the
        # cap makes that worse rather than better, because a tab can
        # push a gap past four columns that a character count kept
        # under it.
        #
        # The four columns are counted from `container_base`, computed at
        # the top of the rule: the container the line is actually INSIDE,
        # which is not always the innermost OPEN one. Measuring from a
        # stale-deep container admits a marker CommonMark does not see —
        # four or more columns past the container the line is really in,
        # the text is indented-code shaped, and indented code cannot
        # interrupt a paragraph, so the line is continuation TEXT.
        # Rewriting the stack from a line that is not a marker leaves
        # every later threshold measured from the wrong place.

        # A BLOCK QUOTE is a container this parser does not model, and
        # `quote_para` is the little of it the setext rule below cannot
        # do without: whether the paragraph CURRENTLY open sits inside
        # one.
        #
        # It lapses with that paragraph. The incoming `para` still holds
        # what the line before left behind, so a paragraph closed
        # anywhere above — by a fence line, by a blank — takes its quote
        # with it and a fresh unquoted paragraph starts clean.
        #
        # A quote marker exists only within four columns of the
        # container the line is inside, on the same terms as the leaf
        # blocks below: past that the line is indented-code shaped and
        # its `>` is code text, not a marker. Reading one there would
        # suppress a setext underline that CommonMark honours.
        #
        # A marker with nothing but blanks after it is a BLANK LINE
        # inside the quote, and it closes the paragraph there the way
        # any blank closes one — so it leaves no paragraph open, inside
        # the quote or outside it, and the line after can be neither a
        # lazy continuation nor a setext underline. Treating it as
        # quoted prose instead keeps `quote_para` raised over a
        # paragraph that has already ended, and the underline CommonMark
        # does honour after it is refused. `quote_blank` carries the
        # other half of that to the paragraph state at the bottom.
        quote_blank = 0
        if (!para) quote_para = 0
        if (ind < container_base + 4 && substr(rest, 1, 1) == ">") {
          if (substr(rest, 2) ~ /[^ \t]/) {
            quote_para = 1
          } else {
            quote_para = 0
            quote_blank = 1
          }
        }

        # Leaf blocks that are NOT paragraphs, recognised before the
        # marker branch because both of the things below need them.
        #
        # They only exist within four columns of the container the line
        # is inside; past that the line is indented-code shaped, and a
        # `#` or `---` there is code text rather than a heading or a
        # break. Inside a paragraph indented code cannot interrupt, so
        # such a line is lazy continuation text and none of these fire.
        #
        # A setext underline is only an underline while a paragraph is
        # open. With no paragraph to underline, `---` is a thematic
        # break (which the test above already catches) and `===` is
        # ordinary text, so this branch reads the INCOMING `para`.
        #
        # It also has to sit at or inside the container holding that
        # paragraph. CommonMark bars a setext underline from being a
        # LAZY continuation line, so `===` at column zero under a list
        # item paragraph is continuation text and the paragraph stays
        # open. Clearing `para` there would hand the following indented
        # line to the code branch even though CommonMark reads it as
        # more of the same paragraph — the UNDER-reporting direction.
        # A heading and a thematic break carry no such rule: either one
        # at column zero really does end the item.
        #
        # `ind >= list_indent` asks that question of LIST containers,
        # the only ones the stack holds. A block quote holds paragraphs
        # just as well and is not modelled at all, so at top level
        # inside one the test is trivially true — `ind` and
        # `list_indent` are both zero — and an underline-shaped lazy
        # continuation reads as a real underline. `quote_para` asks the
        # same question of the container the stack cannot answer for.
        # It needs no indent test of its own: a line carrying the `>`
        # marker is never underline-shaped to this parser, so while a
        # quoted paragraph is open EVERY underline-shaped line is lazy.
        atx = 0
        tbreak = 0
        setext = 0
        if (ind < container_base + 4) {
          atx = is_atx_heading(rest)
          tbreak = is_thematic_break(rest)
          setext = (para && !quote_para && ind >= list_indent &&
                    is_setext_underline(rest))
        }

        # Because neither one can be a lazy continuation, a heading or a
        # break also CLOSES every container it is not indented into,
        # here rather than at the next block boundary. The pop above is
        # skipped while a paragraph is open, so without this a heading
        # at column zero under a list item leaves the item on the stack
        # and the document-level code block after it is measured against
        # a container CommonMark has already closed — four columns in is
        # short of the stale threshold, so the block is emitted as prose.
        if (atx || tbreak) {
          while (depth > 0 && ind < stack[depth]) depth--
          list_indent = 0
          if (depth > 0) list_indent = stack[depth]
        }

        # A thematic break is never a list marker. Where both readings
        # are possible CommonMark gives the break precedence, so `- - -`
        # opens no container; treating it as a marker with a one-column
        # gap invents an item at indent 2 that nothing ever closes, and
        # the code block belonging to the real enclosing container is
        # then measured against the phantom and emitted as prose.
        if (ind < container_base + 4 && !tbreak &&
            match(rest, /^([-*+]|[0-9]+[.)])/)) {
          marker = substr(rest, 1, RLENGTH)
          marker_width = RLENGTH
          tail = substr(rest, RLENGTH + 1)
          gap = tail
          sub(/[^ \t].*$/, "", gap)
          empty_marker = (tail == gap)
          ordered_digits = 0
          if (marker !~ /^[-*+]$/) ordered_digits = length(marker) - 1
          if (ordered_digits > 9) {
            # CommonMark caps an ordered marker at nine digits, so a
            # longer run is not a marker at all. Accepting it is the
            # UNDER-reporting direction: inside a list, a lazy
            # continuation line like `1234567890. more` pops the real
            # item and installs a deeper phantom in its place, and the
            # prose sitting at the real content column is then measured
            # against the phantom and blanked as code with its `#NN`
            # inside. The digit run is measured rather than bounded in
            # the pattern because an interval expression is not
            # portable across every awk CI runs on.
            marker_width = 0
          } else if (!empty_marker && gap == "") {
            marker_width = 0
          } else if (para && !quote_para && ind >= list_indent &&
                     (empty_marker || (marker !~ /^[-*+]$/ &&
                                       !ordered_start_one(marker)))) {
            # A list may only interrupt a paragraph on the terms
            # CommonMark sets: the item must have content on the marker
            # line, and an ORDERED item must start at 1. A line like
            # `2. text` under an open paragraph is still paragraph text.
            # Opening a container for it puts a phantom content indent
            # in force, and the top-level four-space code block after
            # the next blank is measured against the phantom instead of
            # against the document — three columns in rather than four,
            # so it is emitted as prose and its `#NN` fails the check.
            #
            # Interrupting is only what a marker does INSIDE the block
            # holding that paragraph. A marker left of it does not
            # interrupt anything: it closes the container and starts a
            # fresh list, which no rule restricts. Applying the rules
            # there instead refuses a container CommonMark opens, and
            # the lines inside the new item are then measured against
            # the enclosing block and blanked as code — the
            # UNDER-reporting direction.
            #
            # A marker outside the BLOCK QUOTE holding the paragraph is
            # that same marker-left-of-the-block case, which is why
            # `quote_para` bars the restriction as well. The line
            # carries no `>`, so it is not inside the quote; being no
            # more of a paragraph than it is a lazy continuation, it
            # ends the quote and opens its list on the terms of the
            # DOCUMENT, where nothing is being interrupted. CommonMark
            # is explicit about the result: `-` alone under a quoted
            # paragraph opens an empty item, and `2.` opens a list
            # starting at two, neither of which either shape may do
            # under a paragraph of its own block.
            marker_width = 0
          } else if (empty_marker) {
            marker_width = marker_width + 1
            empty_item = 1
          } else {
            gap_cols = visual_span(ind + marker_width, gap)
            if (gap_cols > 4) gap_cols = 1
            marker_width = marker_width + gap_cols
          }
          if (marker_width > 0) {
            while (depth > 0 && stack[depth] > ind) depth--
            depth++
            stack[depth] = ind + marker_width
            list_indent = stack[depth]
          }
        }

        if (!para && ind >= list_indent + 4) {
          indented_code = 1
          indented_code_min = list_indent + 4
          print ""; next
        }

        # `para` records whether a PARAGRAPH is open, not merely whether
        # the last line held text, because that is the only state the
        # "indented code cannot interrupt" rule keys on. An ATX heading,
        # a thematic break and a setext underline are leaf blocks that
        # close (or never open) a paragraph, and an indented code block
        # may begin on the very next line with no blank between. Leaving
        # `para` set after them suppresses both the container pop and the
        # code branch, so a genuine code block after a heading is emitted
        # as prose and a `#NN` inside it fails a required check.
        #
        # A marker that opened an EMPTY item is the same story from the
        # other end: it emits a line and opens a container, but there is
        # no content on it and therefore no paragraph, so the indented
        # code block that may follow it directly is code. A block quote
        # marker with nothing after it is the same again, one container
        # further out: the blank line it stands for closes the paragraph
        # inside the quote, and it closes any paragraph the quote
        # interrupted on its way in, so nothing is left open either way.
        para = 1
        if (atx || tbreak || setext || empty_item || quote_blank) para = 0
        line = strip_code_spans(line)
        gsub(/\]\(#[^)]*\)/, "]()", line)
        print line
      }

      # An ATX heading opener: one to six `#`, then a space, a tab, or
      # end of line. A seventh `#` and a `#` hard against its text are
      # both ordinary paragraph text, which is what keeps a line
      # opening on a bare `#123` from reading as a heading.
      #
      # The run is counted rather than matched with an interval like
      # `#{1,6}`, because interval expressions are not portable across
      # every awk CI runs on.
      function is_atx_heading(s,   n, c) {
        if (substr(s, 1, 1) != "#") return 0
        n = 0
        while (substr(s, n + 1, 1) == "#") n++
        if (n > 6) return 0
        c = substr(s, n + 1, 1)
        return (c == "" || c == " " || c == "\t")
      }

      # A thematic break: three or more of the SAME `-`, `_` or `*`,
      # with nothing but blanks anywhere else on the line.
      function is_thematic_break(s,   c0, i, c, n) {
        c0 = substr(s, 1, 1)
        if (c0 != "-" && c0 != "_" && c0 != "*") return 0
        n = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == c0) n++
          else if (c != " " && c != "\t") return 0
        }
        return (n >= 3)
      }

      # A setext heading underline: one unbroken run of `=` or `-`,
      # then blanks to end of line. The caller decides whether a
      # paragraph is open, which is the only place this shape means an
      # underline at all.
      function is_setext_underline(s,   c0, n, i, c) {
        c0 = substr(s, 1, 1)
        if (c0 != "=" && c0 != "-") return 0
        n = 0
        while (substr(s, n + 1, 1) == c0) n++
        for (i = n + 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c != " " && c != "\t") return 0
        }
        return 1
      }

      # Whether an ordered marker starts at 1, the only start CommonMark
      # lets interrupt a paragraph. The digits are compared with leading
      # zeros removed, matching the integer CommonMark parses, and the
      # result is forced to a string so a bullet marker reaching here by
      # mistake cannot compare equal numerically.
      function ordered_start_one(m,   d) {
        d = m
        sub(/[.)]$/, "", d)
        sub(/^0+/, "", d)
        return ((d "") == "1")
      }

      # Column reached by a run of leading whitespace, with tabs
      # advancing to the next four-column stop (CommonMark). Measuring
      # columns rather than characters is what makes one leading tab
      # count as the four columns it renders as.
      function visual_indent(s) {
        return visual_span(0, s)
      }

      # Columns spanned by a run of blanks that BEGINS at column `col`.
      # A tab is worth whatever it takes to reach the next four-column
      # stop, which is a function of where it starts, so the same run
      # is not the same width everywhere: a leading tab spans four
      # columns, the tab in `-<TAB>item` spans three (column 1 to
      # column 4). `visual_indent` is the special case that starts at
      # column zero.
      function visual_span(col, s,   i, c, start) {
        start = col
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "\t") col += 4 - (col % 4)
          else col++
        }
        return col - start
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

  # Case 42: the carve-out has exactly ONE authored source, and the hub
  # overlay reaches it by pointer rather than by copy.
  #
  # The narration ban itself still exists twice on the hub: once in the
  # canonical shared core (propagated to every consumer) and once in
  # docs/agents/operating-rules.md, the per-repo-owned LOCAL OVERLAY that
  # carries its own copy pending the #780 split. That duplication is
  # tracked debt with a sequenced removal (#780 steps 4-5, canary-first).
  # The carve-out is NOT allowed to join it.
  #
  # An earlier revision of this case did the opposite: it hand-mirrored
  # the carve-out into the overlay and then required the two copies to
  # stay byte-identical. That is two authored sources for one rule,
  # against `docs/agents/code-modification-rules.md` § "Never duplicate
  # logic or instructions", and it enforces by test exactly the hand
  # synchronization the #780 ownership split exists to end — nothing
  # propagates between the two files, so the only thing holding them
  # together would be a byte-compare no consumer benefits from.
  #
  # The right shape, and what this case pins: the overlay POINTS at the
  # canonical carve-out. `AGENTS.md` orders the shared core (entry 2)
  # ahead of the overlay (entry 3), so an agent reaching the overlay has
  # already read the carve-out; the pointer is what stops the overlay's
  # remaining ban bullets reading as a flat ban on their own. Three
  # assertions, and the conjunction is the point:
  #
  #   (1) the canonical file still authors BOTH halves — the carve-out
  #       bullet and the struck-criterion annotation it exempts outside
  #       the heading — so "delete the overlay copy" cannot be satisfied
  #       by deleting the rule from both files;
  #   (2) the overlay restates NEITHER half, anywhere in the file, so a
  #       future edit cannot re-mirror it under a different heading;
  #   (3) the overlay's narration section names the canonical file AND
  #       the carved-out heading, so what remains is a working pointer
  #       rather than a silent deletion that leaves the ban flat
  #       (nathanjohnpayne/mergepath#794).
  CARVE_MARKER="- One narration-shaped section is carved out by name:"
  CRIT_MARKER='- [ ] ~~<criterion>~~ — Discarded YYYY-MM-DD: <reason>'
  SOR_DOC="$ROOT/docs/agents/shared-operating-rules.md"
  OVERLAY_DOC="$ROOT/docs/agents/operating-rules.md"
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
    # If the overlay ever becomes canonical the pointer premise is gone —
    # the sync would then rewrite it — and this case should be rewritten,
    # not silently passed.
    fail "Case 42: expected docs/agents/operating-rules.md class 'per-repo-owned', got (rc=$overlay_rc) '$overlay_class'"
  else
    # The overlay's narration section only — heading exclusive, up to the
    # next level-2 heading — so a pointer parked elsewhere in the file
    # does not satisfy (3).
    ov_narration=$(awk -v h="$NARRATION_HEADING" '
      index($0, h) == 1 { in_sec = 1; next }
      in_sec && /^## / { exit }
      in_sec { print }
    ' "$OVERLAY_DOC")
    set +e
    sor_carve=$(grep -cF -- "$CARVE_MARKER" "$SOR_DOC")
    sor_crit=$(grep -cF -- "$CRIT_MARKER" "$SOR_DOC")
    # (2) scans the WHOLE overlay, not just the narration section.
    ov_carve=$(grep -cF -- "$CARVE_MARKER" "$OVERLAY_DOC")
    ov_crit=$(grep -cF -- "$CRIT_MARKER" "$OVERLAY_DOC")
    ov_ptr_file=$(printf '%s\n' "$ov_narration" | grep -cF 'shared-operating-rules.md')
    ov_ptr_heading=$(printf '%s\n' "$ov_narration" | grep -cF '## Path taken')
    set -e
    if [ -z "$ov_narration" ]; then
      fail "Case 42: $OVERLAY_DOC has no '$NARRATION_HEADING' section"
    elif [ "${sor_carve:-0}" -lt 1 ] || [ "${sor_crit:-0}" -lt 1 ]; then
      fail "Case 42: docs/agents/shared-operating-rules.md no longer authors both halves of the carve-out (bullet hits=${sor_carve:-0}, struck-criterion hits=${sor_crit:-0}) — the overlay's pointer would aim at nothing (nathanjohnpayne/mergepath#794)"
    elif [ "${ov_carve:-0}" -gt 0 ] || [ "${ov_crit:-0}" -gt 0 ]; then
      fail "Case 42: docs/agents/operating-rules.md restates the carve-out (bullet hits=${ov_carve:-0}, struck-criterion hits=${ov_crit:-0}) — a per-repo-owned overlay that nothing syncs cannot hold a second authored copy of a canonical rule; point at it instead (nathanjohnpayne/mergepath#794)"
    elif [ "${ov_ptr_file:-0}" -lt 1 ] || [ "${ov_ptr_heading:-0}" -lt 1 ]; then
      fail "Case 42: docs/agents/operating-rules.md § narration rule does not point at the canonical carve-out (file hits=${ov_ptr_file:-0}, heading hits=${ov_ptr_heading:-0}) — with the copy removed and no pointer, the hub overlay reads as a flat narration ban (nathanjohnpayne/mergepath#788)"
    else
      pass "Case 42: the narration carve-out is authored once in the canonical shared rules, and the hub overlay points at it instead of mirroring it"
    fi
  fi

  # Case 43: § 4's self-recognition rule is neither over- nor
  # under-scoped.
  #
  # docs/agents/decision-records.md is canonical/all (Case 36), so § 4
  # is the fleet-wide instruction every agent follows before it writes
  # a decision comment. Its job is to tell a retry of your own crashed
  # write apart from a re-adoption of a decision the issue superseded,
  # and a rule that gets that wrong posts a duplicate comment — the one
  # failure the hidden markers exist to prevent.
  #
  # Two ways to get it wrong, and this case pins both:
  #
  #   (1) OVER-CLAIM. Deciding it purely by comment ordering rests on
  #       "a crashed run's own write is always the newest, because
  #       nothing has been posted after it" — false the moment a second
  #       agent writes to the same issue. Its record is newer, your own
  #       unfinished write then reads as a superseded earlier adoption,
  #       and you post a second comment for a decision you already
  #       posted. So § 4 must not assert the premise unconditionally,
  #       and must name the concurrent-writer case it fails on.
  #
  #   (2) UNDER-SCOPE. A supersession check scoped to the `decision-`
  #       family alone misses a pivot recorded ONLY as a change-level
  #       `path-taken-` comment (placement 2 emits no decision comment
  #       for that case). The superseded decision then still reads as
  #       the issue's latest `decision-` record, and a later re-adoption
  #       inherits the pre-supersession date and edits the first
  #       adoption's rationale away. So § 4 must require the scan across
  #       BOTH marker families.
  #
  #   (3) DO NOT STOP AT AUTHORSHIP. Whatever § 4 says about whose
  #       write a matched record is, it has settled nothing about
  #       whether that record is still current. A retry that crashed
  #       between the comment and the body still owes the body callout,
  #       and the writer that got in between may have superseded the
  #       very record the retry matched. Finishing the retry then
  #       replaces the newer decision's active callout with the older
  #       record's and records no return to it, so the chronology and
  #       the current disposition disagree. So the bullet that deals in
  #       authorship must carry the retry on to currency and to what
  #       becomes of the standing callout. (Whether authorship is
  #       decidable at all is Case 45's business; this case asserts only
  #       that the three are addressed together.)
  #
  # Assertions run against § 4 only — heading exclusive, up to the next
  # `###` — so wording elsewhere in the file cannot satisfy or trip
  # them (nathanjohnpayne/mergepath#794).
  DR_PATH="docs/agents/decision-records.md"
  if [ ! -f "$ROOT/$DR_PATH" ]; then
    fail "Case 43: $DR_PATH missing on disk"
  else
    idem_sec=$(awk '
      index($0, "### 4. Idempotency") == 1 { in_sec = 1; next }
      in_sec && /^### / { exit }
      in_sec { print }
    ' "$ROOT/$DR_PATH")
    set +e
    # (1) the unconditional premise, and the single-family scoping it
    #     was written with, must both be gone.
    over_claim=$(printf '%s\n' "$idem_sec" | grep -cF 'always the newest')
    family_scoped=$(printf '%s\n' "$idem_sec" | grep -cF 'marker of that family')
    # (1) the limitation must be stated, not merely implied.
    concurrency=$(printf '%s\n' "$idem_sec" | grep -cF 'concurrent writer')
    # (2) one bullet must require BOTH families in the same breath —
    #     naming them separately is what the under-scoped version
    #     already did.
    both_families=$(printf '%s\n' "$idem_sec" \
      | grep -F 'decision-' | grep -F 'path-taken-' | grep -c 'both')
    # (3) the SAME bullet that settles authorship must go on to say the
    #     match does not make the record current and to rule on the
    #     standing callout. The conjunction is the assertion: a bullet
    #     that names authorship alone is the version that restores an
    #     older callout over a newer decision. Prose is soft-wrapped
    #     one line per paragraph, so a bullet is one physical line and
    #     the per-line conjunction really does pin one claim.
    self_currency=$(printf '%s\n' "$idem_sec" \
      | grep -F 'authorship' | grep -F 'currency' | grep -cF 'callout')
    set -e
    if [ -z "$idem_sec" ]; then
      fail "Case 43: $DR_PATH has no '### 4. Idempotency' section"
    elif [ "${over_claim:-0}" -gt 0 ] || [ "${family_scoped:-0}" -gt 0 ]; then
      fail "Case 43: $DR_PATH § 4 still decides retry-vs-re-adoption by comment ordering within one marker family (over-claim hits=${over_claim:-0}, single-family hits=${family_scoped:-0}) — a concurrent writer's comment is newer than your crashed write, so your own record reads as superseded and the retry posts a duplicate (nathanjohnpayne/mergepath#794)"
    elif [ "${concurrency:-0}" -lt 1 ]; then
      fail "Case 43: $DR_PATH § 4 does not name the concurrent-writer case that inverts comment ordering — the limitation has to be stated, not left for the reader to discover (nathanjohnpayne/mergepath#794)"
    elif [ "${both_families:-0}" -lt 1 ]; then
      fail "Case 43: $DR_PATH § 4 has no bullet requiring the supersession scan across BOTH the 'decision-' and 'path-taken-' families — a decision superseded only by a change-level path record still reads as current, and the re-adoption edits the first adoption's rationale away (nathanjohnpayne/mergepath#794)"
    elif [ "${self_currency:-0}" -lt 1 ]; then
      fail "Case 43: $DR_PATH § 4 deals in authorship but never says the match leaves currency open, nor what becomes of the standing callout — a retry that matches its own crashed comment then finishes the body write and swaps a newer decision's active callout for its own older record, with no return to that record recorded anywhere (nathanjohnpayne/mergepath#794)"
    else
      pass "Case 43: § 4 self-recognition states its concurrent-writer limit, scans both marker families, and stops short of the body when the record it matched has been superseded"
    fi
  fi

  # Case 44: the `path-taken-` slug-qualification condition is keyed to
  # the end of the pivot its slug actually names.
  #
  # Placement 2 hands the change-level marker to § 4 wholesale ("§ 4
  # below governs this marker as well"), but the two slug families name
  # OPPOSITE ends of a pivot: a `decision-` slug names the decision
  # ADOPTED, a `path-taken-` slug names the approach ABANDONED. § 4's
  # condition — a return to something the issue once superseded — is
  # therefore the wrong test for a path record, and transcribing it
  # here misses in both directions:
  #
  #   away from `use-postgres`  → slug `use-postgres`
  #   back to `use-postgres`    → slug `use-dynamo`
  #   away from `use-postgres`  → slug `use-postgres` REPEATS
  #
  # Read against the adopted end it qualifies the middle pivot, whose
  # slug never repeated. Read against the approach the slug names it
  # says nothing about the third pivot — the only one that collides —
  # which then keeps the bare `use-postgres`, matches the FIRST pivot's
  # record on § 4's undated search, and gets that record's date and an
  # edit-in-place: the first pivot's chronology overwritten by the
  # third's, which is precisely the loss § 4 exists to prevent.
  #
  # The condition that actually tracks the collision is "an earlier
  # `path-taken-` record already names the approach this pivot is
  # abandoning" — the approach was recorded as abandoned, re-adopted,
  # and is being abandoned again. Pinned three ways: the old
  # adopted-end condition must be gone, one paragraph must state the
  # abandoned-end one, and the qualified-slug derivation must be spelled
  # out for this family rather than left to be inferred from § 4's
  # decision-family example.
  #
  # Assertions run against `### Where the record goes` only — heading
  # exclusive, up to the next level-2 heading, fenced blocks skipped so
  # the `## Path taken` sample inside them does not end the section
  # early (nathanjohnpayne/mergepath#794).
  if [ ! -f "$ROOT/$DR_PATH" ]; then
    fail "Case 44: $DR_PATH missing on disk"
  else
    placement_sec=$(awk '
      index($0, "### Where the record goes") == 1 { in_sec = 1; next }
      in_sec && /^```/ { fence = !fence }
      in_sec && !fence && /^## / { exit }
      in_sec { print }
    ' "$ROOT/$DR_PATH")
    set +e
    # The adopted-end condition, transcribed from § 4, must be gone.
    adopted_end=$(printf '%s\n' "$placement_sec" \
      | grep -cF 'returning to an approach it pivoted away from')
    # One paragraph must key qualification to the abandoned end. Same
    # soft-wrap reasoning as Case 43: one paragraph, one physical line.
    abandoned_end=$(printf '%s\n' "$placement_sec" \
      | grep -F 'path-taken-' | grep -F 'abandon' | grep -c 'twice')
    # …and must show what the qualified slug looks like for a family
    # whose slug names the abandoned approach.
    qualified_slug=$(printf '%s\n' "$placement_sec" \
      | grep -cF 'use-postgres-after-dynamo')
    set -e
    if [ -z "$placement_sec" ]; then
      fail "Case 44: $DR_PATH has no '### Where the record goes' section"
    elif [ "${adopted_end:-0}" -gt 0 ]; then
      fail "Case 44: $DR_PATH placement 2 still qualifies the 'path-taken-' slug on a RETURN to an abandoned approach — that is the 'decision-' family's condition, and it names the wrong pivot: the repeat happens when the same approach is abandoned twice (nathanjohnpayne/mergepath#794)"
    elif [ "${abandoned_end:-0}" -lt 1 ]; then
      fail "Case 44: $DR_PATH placement 2 does not key 'path-taken-' slug qualification to abandoning the same approach twice — the third pivot keeps the bare slug, § 4's family search hits the FIRST pivot's record, and the second pivot having superseded it sends an ordinary third pivot to § 4's halt instead of recording it (nathanjohnpayne/mergepath#794)"
    elif [ "${qualified_slug:-0}" -lt 1 ]; then
      fail "Case 44: $DR_PATH placement 2 states the condition but never shows the qualified 'path-taken-' slug it produces — § 4's only worked example is a decision-family re-adoption, so the derivation is left to be inferred across the very asymmetry this paragraph exists to flag (nathanjohnpayne/mergepath#794)"
    else
      pass "Case 44: the 'path-taken-' slug is qualified on the abandoned end of the pivot, with its derivation spelled out"
    fi
  fi

  # Case 45: § 4 does not infer authorship from matching content, and
  # routes the case no local read can decide to the halt.
  #
  # § 4's self-recognition rule has been rewritten three times, each
  # round swapping one insufficient signal for another: the marker's
  # date, then comment recency, then the CONTENT of the matched record.
  # Content is the one that looks sound and is not. It refutes — a
  # record stating some other decision cannot be the write you are
  # retrying — but it cannot confirm, because a legitimate re-adoption
  # reproduces the earlier adoption's content exactly whenever the
  # reasons for returning have not changed:
  #
  #   adopt use-postgres        → comment A, bare slug
  #   supersede with use-dynamo → comment B
  #   re-adopt use-postgres     → keys away from A, and A already states
  #                               the very decision being re-adopted
  #
  # Read as proof of authorship, A is "your own unfinished write"; the
  # currency scan then finds B and the procedure halts, so the qualified
  # `use-postgres-after-dynamo` comment and the callout replacement that
  # §§ 4-5 require are never written. A valid third pivot is suppressed
  # by a test that was never entitled to decide the question.
  #
  # Nothing local can decide it. A per-write identifier would have to be
  # unique to one write AND recomputable by a retry holding no local
  # state, and the comments API offers no compare-and-swap to arbitrate.
  # So the honest rule states the limit and sends the undecidable case
  # to the branch that cannot duplicate — leave the record standing,
  # write nothing, surface the conflict — instead of acquiring a fifth
  # inference. Pinned four ways: the two sentences that asserted
  # authorship from content must be gone; the refutes-but-cannot-confirm
  # asymmetry must be stated, so content is not silently promoted back
  # to a proof; the reason no per-write identifier is available must be
  # given, so the next round does not "fix" this by inventing one; and
  # the halt must be keyed to the two readings coming apart rather than
  # to any finding about whose write it was
  # (nathanjohnpayne/mergepath#794).
  if [ ! -f "$ROOT/$DR_PATH" ]; then
    fail "Case 45: $DR_PATH missing on disk"
  else
    idem45_sec=$(awk '
      index($0, "### 4. Idempotency") == 1 { in_sec = 1; next }
      in_sec && /^### / { exit }
      in_sec { print }
    ' "$ROOT/$DR_PATH")
    set +e
    # The two sentences that carried the authorship claim.
    authorship_claim=$(printf '%s\n' "$idem45_sec" \
      | grep -cF -e 'Content is the anchor' -e 'settles *authorship*')
    # The asymmetry itself, in one breath — "it refutes" alone reads as
    # an endorsement of the content test.
    refute_only=$(printf '%s\n' "$idem45_sec" \
      | grep -F 'refutes' | grep -cF 'confirm')
    # Why the identifier Codex proposed cannot exist, not merely that it
    # does not: uniqueness and recomputability-after-a-crash pull apart.
    no_identifier=$(printf '%s\n' "$idem45_sec" \
      | grep -F 'identifier' | grep -cF 'recomputable')
    # The halt, justified by the readings diverging rather than by an
    # authorship verdict. Same soft-wrap reasoning as Case 43: one
    # bullet is one physical line, so the conjunction pins one claim.
    halt_readings=$(printf '%s\n' "$idem45_sec" \
      | grep -F 'cannot duplicate' | grep -F 'readings' | grep -cF 'write nothing')
    set -e
    if [ -z "$idem45_sec" ]; then
      fail "Case 45: $DR_PATH has no '### 4. Idempotency' section"
    elif [ "${authorship_claim:-0}" -gt 0 ]; then
      fail "Case 45: $DR_PATH § 4 still reads a content match as proof that the record is your own write (hits=${authorship_claim:-0}) — an issue re-adopting a decision whose reasons have not changed reproduces the earlier adoption's content exactly, so the re-adoption is misread as a retry and the qualified comment §§ 4-5 require is never written (nathanjohnpayne/mergepath#794)"
    elif [ "${refute_only:-0}" -lt 1 ]; then
      fail "Case 45: $DR_PATH § 4 does not state that content refutes authorship without confirming it — a reader left with 'check the content' applies it in the direction it cannot support (nathanjohnpayne/mergepath#794)"
    elif [ "${no_identifier:-0}" -lt 1 ]; then
      fail "Case 45: $DR_PATH § 4 does not say why no durable per-write identifier is available — unique-per-write and recomputable-by-a-stateless-retry pull apart, and without that the next round closes the gap by inventing the identifier § 2 already rejected as a counter (nathanjohnpayne/mergepath#794)"
    elif [ "${halt_readings:-0}" -lt 1 ]; then
      fail "Case 45: $DR_PATH § 4 does not route the undecidable case to the branch that cannot duplicate on the grounds that the two readings diverge — a halt justified by an authorship verdict is the same over-claim wearing a safer outcome (nathanjohnpayne/mergepath#794)"
    else
      pass "Case 45: § 4 treats content as refuting but never confirming authorship, says why no per-write identifier can settle it, and halts on the undecidable case"
    fi
  fi

  # Case 46: § 4 searches the slug family BEFORE it decides on a
  # qualifier, so the safeguards that run on a match are actually
  # reachable.
  #
  # An earlier revision had the agent classify itself before searching:
  # read the issue's recorded history, decide retry-vs-re-adoption from
  # it, and search under the key that classification implies. That
  # ordering is unsound because the classification is drawn from history
  # a concurrent writer can change:
  #
  #   run posts `use-postgres`, crashes before the body write
  #   another writer records `use-dynamo`
  #   the retry re-derives → "the issue moved off use-postgres, so this
  #     is a re-adoption" → searches ONLY `use-postgres-after-dynamo`
  #
  # No write has ever used that key, so the search misses the retry's
  # OWN comment and it posts a duplicate — and every safeguard § 4 added
  # for exactly this case (content refutation, the currency scan, the
  # halt) is skipped, because all of them run only once something has
  # matched. The pre-search classification is one more inference about
  # whose write a record is, which Case 45 established § 4 cannot make.
  #
  # The fix is an ordering, not a sharper inference: search a key that
  # spans the base slug AND every qualification of it, then let the
  # bullets disposition what comes back. Pinned three ways: the old
  # pre-search wording must be gone; the comment key must wildcard the
  # qualifier rather than compute it; and one bullet must state that
  # qualification is an output of the search while naming the
  # skipped-safeguards consequence of getting it backwards
  # (nathanjohnpayne/mergepath#794).
  if [ ! -f "$ROOT/$DR_PATH" ]; then
    fail "Case 46: $DR_PATH missing on disk"
  else
    idem46_sec=$(awk '
      index($0, "### 4. Idempotency") == 1 { in_sec = 1; next }
      in_sec && /^### / { exit }
      in_sec { print }
    ' "$ROOT/$DR_PATH")
    set +e
    # The two phrasings that carried the pre-search classification.
    pre_search=$(printf '%s\n' "$idem46_sec" \
      | grep -cF -e 'qualify it *before* you search' -e 'readable before you search')
    # The key itself must admit an unknown qualifier. This is the
    # concrete artifact, not a paraphrase: a key without it cannot match
    # a qualified write the retry did not predict.
    family_key=$(printf '%s\n' "$idem46_sec" | grep -cF '(-[a-z0-9-]+)?')
    # Ordering stated as a rule, in the same breath as what breaks
    # without it. Prose is soft-wrapped one line per paragraph, so a
    # bullet is one physical line and the conjunction pins one claim.
    output_not_input=$(printf '%s\n' "$idem46_sec" \
      | grep -F 'chosen after the search' | grep -cF 'run only on a match')
    set -e
    if [ -z "$idem46_sec" ]; then
      fail "Case 46: $DR_PATH has no '### 4. Idempotency' section"
    elif [ "${pre_search:-0}" -gt 0 ]; then
      fail "Case 46: $DR_PATH § 4 still settles the qualifier before searching (hits=${pre_search:-0}) — a concurrent writer between the crash and the retry makes the retry key on a slug no write ever used, so it misses its own comment and duplicates it (nathanjohnpayne/mergepath#794)"
    elif [ "${family_key:-0}" -lt 1 ]; then
      fail "Case 46: $DR_PATH § 4's comment search key does not wildcard the qualifier — a key built from a computed qualifier cannot match a qualified write the retry did not predict, and a key built from the bare slug alone cannot match one it did (nathanjohnpayne/mergepath#794)"
    elif [ "${output_not_input:-0}" -lt 1 ]; then
      fail "Case 46: $DR_PATH § 4 does not state that the qualifier is chosen after the search, nor that getting it backwards skips the safeguards that only run on a match — the ordering is the whole fix, so leaving it implicit invites the next round to re-derive the key up front (nathanjohnpayne/mergepath#794)"
    else
      pass "Case 46: § 4 searches the base slug and every qualification of it, then chooses the qualifier from what came back"
    fi
  fi

  # Case 47: accepting a recommendation is a supersession § 4 must not
  # swallow as a retry.
  #
  # §§ 1-2 give a pending recommendation its own heading and its own
  # callout wording; § 5 says accepting one is a supersession. But the
  # acceptance adopts the SAME decision, so it derives the same base
  # slug and § 4's search matches the recommendation's own comment:
  #
  #   recommend use-postgres → comment, callout reads
  #                            "**Decision recommendation recorded:**"
  #   accept it unchanged    → same base slug → matches that comment,
  #                            nothing posted after it supersedes it
  #
  # § 4's currency bullet then reads the pair of readings as coinciding
  # and has the writer finish under the matched record and post no new
  # comment. The acceptance is never recorded: the issue keeps a body
  # callout announcing a recommendation for a decision that has actually
  # been settled, which is the entrypoint-misstates-the-disposition
  # failure this whole convention exists to prevent — reached through
  # the machinery meant to prevent it.
  #
  # Status is the discriminator, and unlike authorship it IS decidable
  # from a local read: the matched comment's own heading says whether it
  # stands as a recommendation or a decision. So this case is not a
  # sixth inference — it is a fact § 4 was ignoring. Pinned three ways:
  # one bullet must tie status to the recommendation/acceptance pair and
  # name the stale callout it produces; the currency bullet's
  # finish-and-post-nothing branch must be gated on status so it cannot
  # swallow an acceptance; and the acceptance must get a qualified slug
  # of its own rather than colliding with the recommendation's
  # (nathanjohnpayne/mergepath#794).
  if [ ! -f "$ROOT/$DR_PATH" ]; then
    fail "Case 47: $DR_PATH missing on disk"
  else
    idem47_sec=$(awk '
      index($0, "### 4. Idempotency") == 1 { in_sec = 1; next }
      in_sec && /^### / { exit }
      in_sec { print }
    ' "$ROOT/$DR_PATH")
    set +e
    # One bullet, all three terms — naming them in separate paragraphs
    # is what the version this case replaces already did.
    status_bullet=$(printf '%s\n' "$idem47_sec" \
      | grep -F 'recommendation' | grep -F 'acceptance' | grep -c 'status')
    # …and it must name the observable failure, not just the rule.
    stale_callout=$(printf '%s\n' "$idem47_sec" \
      | grep -cF 'Decision recommendation recorded')
    # The currency branch that posts nothing must be status-gated.
    currency_gated=$(printf '%s\n' "$idem47_sec" \
      | grep -F 'same status' | grep -cF 'post no second comment')
    # The acceptance's own key, spelled out — the re-adoption
    # derivation ("the slug of the record it supersedes") degenerates
    # here, because the record it supersedes carries the same slug.
    accept_slug=$(printf '%s\n' "$idem47_sec" | grep -cF 'use-postgres-accepted')
    set -e
    if [ -z "$idem47_sec" ]; then
      fail "Case 47: $DR_PATH has no '### 4. Idempotency' section"
    elif [ "${status_bullet:-0}" -lt 1 ] || [ "${stale_callout:-0}" -lt 1 ]; then
      fail "Case 47: $DR_PATH § 4 does not make status part of what a record states (status hits=${status_bullet:-0}, stale-callout hits=${stale_callout:-0}) — an acceptance derives the recommendation's own base slug, so § 4 matches its comment and § 5's supersession never happens (nathanjohnpayne/mergepath#794)"
    elif [ "${currency_gated:-0}" -lt 1 ]; then
      fail "Case 47: $DR_PATH § 4's finish-under-the-matched-record branch is not gated on status — it fires on the recommendation an acceptance matches, so the acceptance posts nothing and the issue keeps a callout labelling a settled decision a recommendation (nathanjohnpayne/mergepath#794)"
    elif [ "${accept_slug:-0}" -lt 1 ]; then
      fail "Case 47: $DR_PATH § 4 never shows the acceptance's qualified slug — the re-adoption derivation degenerates here because the record being superseded carries the same base slug, so leaving it to be inferred produces a collision or a counter (nathanjohnpayne/mergepath#794)"
    else
      pass "Case 47: § 4 treats a recommendation and its acceptance as two records, and gives the acceptance its own key"
    fi
  fi

  # Case 48: INDENTED code blocks are code too (#781 item 9).
  #
  # Cases 38-40 only ever fence their code, so the scan treated a
  # four-space-indented block as prose and flagged every `#NN` in it —
  # a false positive failing a required check on a doc whose refs are
  # code. The second half of the fixture pins the direction that matters
  # more: the four-space continuation paragraph of a `1. ` list item is
  # prose (the item's content indent is 3, so code would need seven),
  # and its bare ref MUST still be flagged. A fix that measured the four
  # columns from column zero would silently swallow it.
  INDENT_DOC="$WORKDIR/consumer-truth-indent.md"
  cat > "$INDENT_DOC" <<'INDENT_EOF'
# Doc

An indented code block follows, four spaces in:

    echo "#111 is not a ref"
    grep -n '#222' file

Back to prose.

1. A numbered step, whose content indent is three columns.

    A four-space continuation of that item mentioning #333 is prose.

But a bare #444 in prose is.
INDENT_EOF
  set +e
  indent_hits=$(md_prose_only "$INDENT_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  indent_lines=$(md_prose_only "$INDENT_DOC" | wc -l | tr -d ' ')
  indent_raw=$(wc -l < "$INDENT_DOC" | tr -d ' ')
  set -e
  if [ "$indent_hits" != "12,14," ]; then
    fail "Case 48: expected lines 12,14 flagged (indented code excluded, list continuation kept), got '$indent_hits'"
  elif [ "$indent_lines" != "$indent_raw" ]; then
    fail "Case 48: md_prose_only must emit one line per input line, got $indent_lines for $indent_raw"
  else
    pass "Case 48: indented code excluded, but a list item's indented continuation is still scanned"
  fi

  # Case 49: a backtick fence opener may not carry a backtick in its
  # info string (#781 item 10).
  #
  # Line 3 is not a delimiter per CommonMark, it is a paragraph line.
  # Accepting it as an opener mis-tracked fence state in BOTH harmful
  # directions at once: the real prose ref on line 4 was blanked as
  # fence content, and the doc's next genuine opener (line 6) was eaten
  # as the closer, so the genuinely fenced #222 on line 7 surfaced as a
  # false positive — and every later line, including the real ref on
  # line 14, stayed swallowed inside a fence that was never opened. The
  # tilde block pins the other half of the rule: a TILDE opener's info
  # string MAY hold a backtick, so #333 must stay hidden.
  OPENER_DOC="$WORKDIR/consumer-truth-opener.md"
  cat > "$OPENER_DOC" <<'OPENER_EOF'
# Doc

```js `inline` example
A bare #111 here is real prose, not fence content.

```
Genuine fenced content mentioning #222.
```

~~~js `inline`
A tilde info string MAY hold a backtick, so #333 stays hidden.
~~~

But a bare #444 in prose is.
OPENER_EOF
  set +e
  opener_hits=$(md_prose_only "$OPENER_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  opener_lines=$(md_prose_only "$OPENER_DOC" | wc -l | tr -d ' ')
  opener_raw=$(wc -l < "$OPENER_DOC" | tr -d ' ')
  set -e
  if [ "$opener_hits" != "4,14," ]; then
    fail "Case 49: expected lines 4,14 flagged (invalid backtick opener is prose; tilde opener is a fence), got '$opener_hits'"
  elif [ "$opener_lines" != "$opener_raw" ]; then
    fail "Case 49: md_prose_only must emit one line per input line, got $opener_lines for $opener_raw"
  else
    pass "Case 49: a backtick opener with a backtick in its info string is prose, not a fence"
  fi

  # Case 50: the indented-code threshold is relative ALL THE WAY DOWN
  # (#781 item 9, nested lists).
  #
  # Case 48 only nests one `1. ` item at column zero, so it passes even
  # if the list container stops being tracked at the first sub-list.
  # This fixture pins the direction that case cannot see. Measuring a
  # nested marker against an absolute four columns instead of against
  # the CURRENT container leaves the threshold pinned to the OUTERMOST
  # item, and everything below the first sub-list — its own prose, its
  # continuation paragraph, its children — is blanked as code. That is
  # UNDER-reporting: a bare ref silently shipped to every consumer,
  # which is the failure direction this parser must never take. Two
  # levels of four-space nesting is ordinary markdown, so lines 5, 7
  # and 9 must all be flagged.
  #
  # The back half pins the exclusion the relative measure must NOT
  # lose: at four columns past the innermost container (14 here, from a
  # content indent of 10) it really is code, as is a plain four-space
  # block once the list has ended at column zero.
  NEST_DOC="$WORKDIR/consumer-truth-nest.md"
  cat > "$NEST_DOC" <<'NEST_EOF'
# Doc

- a

    - b mentioning #111

        Continuation of b mentioning #222.

        - c mentioning #333

              deep code mentioning #444

Back at column zero.

    Plain code mentioning #555

And a bare #666 in prose is.
NEST_EOF
  set +e
  nest_hits=$(md_prose_only "$NEST_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  nest_lines=$(md_prose_only "$NEST_DOC" | wc -l | tr -d ' ')
  nest_raw=$(wc -l < "$NEST_DOC" | tr -d ' ')
  set -e
  if [ "$nest_hits" != "5,7,9,17," ]; then
    fail "Case 50: expected lines 5,7,9,17 flagged (nested list prose is prose; only deep code excluded), got '$nest_hits'"
  elif [ "$nest_lines" != "$nest_raw" ]; then
    fail "Case 50: md_prose_only must emit one line per input line, got $nest_lines for $nest_raw"
  else
    pass "Case 50: the code threshold follows nested list containers, so nested prose stays scanned"
  fi

  # Case 51: a marker with nothing after it opens an EMPTY list item,
  # and that item is a container like any other.
  #
  # Case 50 nests only markers that carry text, so it passes even if the
  # marker pattern demands whitespace after every marker. Line 5 here is
  # a bare `-`: CommonMark opens a nested item whose content indent is
  # the marker width plus one (4), so the six-space paragraphs on lines
  # 6 and 8 are its prose and the ten-space line 10 is its code. Skip
  # the bare marker and the threshold stays pinned to the OUTER item at
  # 2, which puts line 8 at exactly the code cut-off — blanked, and its
  # ref shipped unflagged. That is the UNDER-reporting direction, the
  # one this parser must never take. Line 6 is protected only because a
  # code block cannot interrupt the paragraph the marker line opened, so
  # a fixture with one continuation line cannot see this at all.
  EMPTY_DOC="$WORKDIR/consumer-truth-empty-marker.md"
  cat > "$EMPTY_DOC" <<'EMPTY_EOF'
# Doc

- outer

  -
      Prose in the empty item mentioning #111.

      More of that prose mentioning #222.

          Code inside that item mentioning #333.

And a bare #444 in prose is.
EMPTY_EOF
  set +e
  empty_hits=$(md_prose_only "$EMPTY_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  empty_lines=$(md_prose_only "$EMPTY_DOC" | wc -l | tr -d ' ')
  empty_raw=$(wc -l < "$EMPTY_DOC" | tr -d ' ')
  set -e
  if [ "$empty_hits" != "6,8,12," ]; then
    fail "Case 51: expected lines 6,8,12 flagged (empty marker opens a container; only line 10 is code), got '$empty_hits'"
  elif [ "$empty_lines" != "$empty_raw" ]; then
    fail "Case 51: md_prose_only must emit one line per input line, got $empty_lines for $empty_raw"
  else
    pass "Case 51: a bare list marker opens an empty item, so its prose is still scanned"
  fi

  # Case 52: list containers must CLOSE when the document outdents.
  #
  # Cases 48 and 50 only ever go deeper, so they pass even if the
  # container indent is never popped below column zero. Here the doc
  # returns from the four-space sublist to the outer item: line 7 sits
  # at the outer content indent of 2, which ends the sublist, so the
  # six-space line 9 is four columns past the OUTER item and is that
  # item's indented code block. Carrying the sublist content indent of 6
  # forward puts the cut-off at 10 instead, and line 9 is emitted as
  # prose — a FALSE POSITIVE failing a required check on a `#NN` that is
  # code. The same six-space block four columns inside a column-zero
  # item is excluded in case 41; classification must not depend on
  # whether a now-closed sublist happened to precede it.
  OUTDENT_DOC="$WORKDIR/consumer-truth-outdent.md"
  cat > "$OUTDENT_DOC" <<'OUTDENT_EOF'
# Doc

- a

    - b mentioning #111

  Outer continuation mentioning #222.

      echo "#333 is code"

And a bare #444 in prose is.
OUTDENT_EOF
  set +e
  outdent_hits=$(md_prose_only "$OUTDENT_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  outdent_lines=$(md_prose_only "$OUTDENT_DOC" | wc -l | tr -d ' ')
  outdent_raw=$(wc -l < "$OUTDENT_DOC" | tr -d ' ')
  set -e
  if [ "$outdent_hits" != "5,7,11," ]; then
    fail "Case 52: expected lines 5,7,11 flagged (sublist closes on outdent, so line 9 is outer-item code), got '$outdent_hits'"
  elif [ "$outdent_lines" != "$outdent_raw" ]; then
    fail "Case 52: md_prose_only must emit one line per input line, got $outdent_lines for $outdent_raw"
  else
    pass "Case 52: a nested list closes on outdent, so the outer item's indented code is still excluded"
  fi

  # Case 53: an EMPTY list item closes at the next blank line.
  #
  # Case 51 pins that a bare marker OPENS a container; nothing pinned that
  # it ever closes, and an item that is opened but never closed leaves the
  # threshold permanently too deep. Per CommonMark a list item may begin
  # with at most one blank line, so a bare marker followed by a blank ENDS
  # the list and the base indent returns to the enclosing container.
  #
  # Both directions of "enclosing" are pinned, because a close that
  # over-shoots to column zero is as wrong as no close at all. Line 3 is
  # at the top level, so line 5 is a top-level indented code block four
  # columns in. Line 9 is nested inside `- outer`, so closing it must
  # return to that item's content indent of 2 and NOT to zero, which is
  # what makes the six-space line 11 that item's code and leaves the
  # two-space line 13 its prose.
  #
  # Keeping the empty item open instead puts the cut-off at 4 and 8, both
  # short of those lines, and each is emitted as prose — a FALSE POSITIVE
  # failing a required check on a `#NN` that is code. Expected
  # classifications come from markdown-it-py in commonmark mode, which
  # renders lines 5 and 11 inside `<pre><code>`.
  CLOSE_DOC="$WORKDIR/consumer-truth-empty-close.md"
  cat > "$CLOSE_DOC" <<'CLOSE_EOF'
# Doc

-

    Code after the empty item mentioning #111.

- outer

  -

      Code back in the outer item mentioning #222.

  Outer continuation mentioning #333.

And a bare #444 in prose is.
CLOSE_EOF
  set +e
  close_hits=$(md_prose_only "$CLOSE_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  close_lines=$(md_prose_only "$CLOSE_DOC" | wc -l | tr -d ' ')
  close_raw=$(wc -l < "$CLOSE_DOC" | tr -d ' ')
  set -e
  if [ "$close_hits" != "13,15," ]; then
    fail "Case 53: expected lines 13,15 flagged (a blank closes the empty item, so lines 5 and 9 open no lasting container), got '$close_hits'"
  elif [ "$close_lines" != "$close_raw" ]; then
    fail "Case 53: md_prose_only must emit one line per input line, got $close_lines for $close_raw"
  else
    pass "Case 53: an empty list item closes at the next blank line, so the code that follows is still excluded"
  fi

  # Case 54: a marker is measured from the container the line is IN.
  #
  # Line 4 looks like a marker but is not one. The item opened on line 3
  # has its content indent at 5, so a line at 4 columns is outdented back
  # out of that item, and against the enclosing container — the document —
  # four columns is indented-code shaped. Indented code cannot interrupt a
  # paragraph, so CommonMark reads line 4 as continuation TEXT of line 3's
  # paragraph, which is why it renders inside the same `<p>`.
  #
  # Measuring the marker allowance against the innermost OPEN container
  # instead accepts it, and a line that is not a marker then rewrites the
  # container stack: it discards the real item at 5 and opens its own. Once
  # closing is honest — case 46 — the phantom is closed at line 5 too, and
  # the stack is left empty. Line 6 is then four columns past nothing
  # rather than three columns inside the item, blanked as code, and its
  # `#222` ships unflagged. That is the UNDER-reporting direction, the one
  # this parser must never take, so the allowance is counted from the
  # container the line is actually inside. At a block boundary the two are
  # the same number, which is why cases 41 and 43 are unmoved.
  BASE_DOC="$WORKDIR/consumer-truth-marker-base.md"
  cat > "$BASE_DOC" <<'BASE_EOF'
# Doc

   * item mentioning #111
    10.

        Prose in that item mentioning #222.
BASE_EOF
  set +e
  base_hits=$(md_prose_only "$BASE_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  base_lines=$(md_prose_only "$BASE_DOC" | wc -l | tr -d ' ')
  base_raw=$(wc -l < "$BASE_DOC" | tr -d ' ')
  set -e
  if [ "$base_hits" != "3,6," ]; then
    fail "Case 54: expected lines 3,6 flagged (line 4 is continuation text, not a marker, so the item stays open), got '$base_hits'"
  elif [ "$base_lines" != "$base_raw" ]; then
    fail "Case 54: md_prose_only must emit one line per input line, got $base_lines for $base_raw"
  else
    pass "Case 54: the marker allowance is measured from the container the line is inside, so a lazy continuation cannot rewrite the stack"
  fi

  # Case 55: the gap after a list marker is measured in COLUMNS, capped
  # at four.
  #
  # Every marker in cases 41-47 is followed by spaces, where one
  # character is one column, so all of them pass under a character
  # count. A tab is not one column: it advances to the next four-column
  # stop, so its width depends on where the marker leaves off. Both
  # fixtures are written with `printf` rather than a heredoc so the tab
  # is unmistakable in the source and survives any editor that would
  # helpfully expand it.
  #
  # The first document is the measurement. In `-<TAB>item` the tab
  # starts at column 1 and spans three columns, putting the item's
  # content indent at 4 and its code threshold at 8. A character count
  # calls the gap one column, puts the content indent at 2 and the
  # threshold at 6, and blanks the six-column line — which CommonMark
  # renders as a paragraph inside the item — as indented code. Its
  # `#222` then ships unflagged, the UNDER-reporting direction this
  # parser must never take.
  #
  # The second document is the cap that has to travel with the
  # measurement. CommonMark counts at most four columns of gap; five or
  # more means the item STARTS with indented code and the content indent
  # is the marker width plus one. `10)<SP><TAB>` spans five columns, so
  # measuring honestly but WITHOUT the cap sets the container at 8 —
  # deeper than the character count's 5, and deeper than CommonMark's 4.
  # An over-deep container is not the harmless over-scan it looks like,
  # because the pop loop compares against it: the five-column line 5,
  # which CommonMark reads as a nested item inside the outer one, sits
  # left of the phantom indent, closes the container, is measured
  # against the document instead, and is blanked as code with `#111`
  # inside it. Honest columns without the cap are therefore WORSE than
  # the character count they replace, not better.
  TABGAP_DOC="$WORKDIR/consumer-truth-tab-gap.md"
  printf '# Doc\n\n-\titem mentioning #111\n\n      Prose in that item mentioning #222.\n' \
    > "$TABGAP_DOC"
  set +e
  tabgap_hits=$(md_prose_only "$TABGAP_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  tabgap_lines=$(md_prose_only "$TABGAP_DOC" | wc -l | tr -d ' ')
  tabgap_raw=$(wc -l < "$TABGAP_DOC" | tr -d ' ')
  set -e
  CAPGAP_DOC="$WORKDIR/consumer-truth-wide-gap.md"
  printf '# Doc\n\n10) \tan item whose content is indented code\n\n     10)   Nested item mentioning #111.\n' \
    > "$CAPGAP_DOC"
  set +e
  capgap_hits=$(md_prose_only "$CAPGAP_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  if [ "$tabgap_hits" != "3,5," ]; then
    fail "Case 55: expected lines 3,5 flagged (the tab after the marker spans three columns, so line 5 is prose inside the item), got '$tabgap_hits'"
  elif [ "$tabgap_lines" != "$tabgap_raw" ]; then
    fail "Case 55: md_prose_only must emit one line per input line, got $tabgap_lines for $tabgap_raw"
  elif [ "$capgap_hits" != "5," ]; then
    fail "Case 55: expected line 5 flagged (a five-column gap caps the content indent at the marker width plus one, so the nested item stays inside), got '$capgap_hits'"
  else
    pass "Case 55: the marker gap is measured in visual columns and capped at four, so tabbed list items neither under-scan nor open a phantom container"
  fi

  # Case 56: only a PARAGRAPH blocks an indented code block.
  #
  # Every fixture in cases 38-48 puts a blank line between a leaf block
  # and the code that follows it, so all of them pass even if the parser
  # treats "the last line held text" as "a paragraph is open". CommonMark
  # bars indented code from interrupting a PARAGRAPH and nothing else: an
  # ATX heading, a setext heading, a thematic break and an empty list
  # item all leave no paragraph behind, so a code block may start on the
  # very next line with no blank between. Reading every emitted line as a
  # paragraph suppresses both the container pop and the code branch
  # there, and lines 2, 6, 10, 14 and 17 — which markdown-it-py in
  # commonmark mode renders inside `<pre><code>` — are emitted as prose
  # with their `#NN` exposed. That is the FALSE POSITIVE direction,
  # failing a required check on a doc whose refs are code.
  #
  # Line 13 pins the other half: a heading is never a lazy continuation,
  # so it closes the item opened on line 12 as well, which is what leaves
  # line 14 four columns past the DOCUMENT rather than short of a stale
  # container indent of 2. Line 9 is spaced out as `* * *` so that the
  # break is also a list-marker shape: CommonMark gives the break
  # precedence, and reading it as a marker instead opens an item at
  # indent 2 that nothing closes, leaving line 10 short of the threshold
  # and emitted as prose.
  #
  # The second document is the one exception, and it runs the other way.
  # A setext underline may not be a LAZY continuation line, so the `===`
  # on line 4 — left of the item holding the paragraph — underlines
  # nothing and the paragraph runs on. Treating it as a heading closes
  # the paragraph, and line 5 is then four columns past the item and
  # blanked as code with its `#222` inside — the UNDER-reporting
  # direction. Both classifications are markdown-it-py in commonmark
  # mode, which renders lines 3-5 as one `<li>` paragraph.
  LEAF_DOC="$WORKDIR/consumer-truth-leaf-blocks.md"
  cat > "$LEAF_DOC" <<'LEAF_EOF'
# Doc
    echo "#111 is code"

Prose that a setext underline turns into a heading.
===
    echo "#222 is code"

Prose that a thematic break interrupts.
* * *
    echo "#333 is code"

- An item mentioning #444
# A heading closes that item
    echo "#555 is code"

-
      echo "#666 is code"

But a bare #777 in prose is.
LEAF_EOF
  set +e
  leaf_hits=$(md_prose_only "$LEAF_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  leaf_lines=$(md_prose_only "$LEAF_DOC" | wc -l | tr -d ' ')
  leaf_raw=$(wc -l < "$LEAF_DOC" | tr -d ' ')
  set -e
  LAZY_DOC="$WORKDIR/consumer-truth-lazy-setext.md"
  cat > "$LAZY_DOC" <<'LAZY_EOF'
# Doc

- An item mentioning #111
===
      Still that same paragraph, mentioning #222.

And a bare #333 in prose is.
LAZY_EOF
  set +e
  lazy_hits=$(md_prose_only "$LAZY_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  if [ "$leaf_hits" != "12,19," ]; then
    fail "Case 56: expected lines 12,19 flagged (a heading, a setext underline, a break and an empty item all leave no paragraph, so the code after each is excluded), got '$leaf_hits'"
  elif [ "$leaf_lines" != "$leaf_raw" ]; then
    fail "Case 56: md_prose_only must emit one line per input line, got $leaf_lines for $leaf_raw"
  elif [ "$lazy_hits" != "3,5,7," ]; then
    fail "Case 56: expected lines 3,5,7 flagged (a setext underline cannot be a lazy continuation, so the paragraph runs on), got '$lazy_hits'"
  else
    pass "Case 56: an indented code block may follow a leaf block directly, so only a real paragraph keeps the scan on"
  fi

  # Case 57: a list opens only where CommonMark lets one open.
  #
  # The first document is the restriction. A list may interrupt a
  # paragraph only if the item carries content AND, when ordered, starts
  # at 1. Line 4 satisfies neither test, so it is still paragraph text;
  # opening a container for it puts the content indent at 3 and the
  # top-level code block on line 6 lands three columns past it rather
  # than four, is emitted as prose, and fails a required check on the
  # `#111` inside it. Line 14 is the same story for an empty marker,
  # which CommonMark reads here as a setext underline. Lines 9 and 11
  # pin that a conforming `1. ` item is unaffected.
  #
  # The second document is the limit on that restriction, which matters
  # more because it runs the other way. Interrupting is what a marker
  # does INSIDE the block holding the paragraph; a marker to the LEFT of
  # it closes that block and starts a fresh list, which no rule
  # restricts. Line 4 opens an item whose content indent is 6, so line 6
  # is its paragraph. Refuse that container and line 6 is measured
  # against the `- outer` item at 2 instead, four columns in, and its
  # `#222` is blanked as code — the UNDER-reporting direction this
  # parser must never take. Line 9 is the empty-marker form of the same
  # allowance, and the six-column line 10 is then that new item's code.
  #
  # Every classification here is markdown-it-py in commonmark mode.
  INTERRUPT_DOC="$WORKDIR/consumer-truth-interrupt.md"
  cat > "$INTERRUPT_DOC" <<'INTERRUPT_EOF'
# Doc

Prose paragraph one.
2. not a list, because an ordered list must start at 1 to interrupt

    echo "#111 is code"

Prose paragraph two.
1. a real item mentioning #222

    A four-space continuation of that item mentioning #333.

Prose paragraph three.
-
    echo "#444 is code"

And a bare #555 in prose is.
INTERRUPT_EOF
  set +e
  interrupt_hits=$(md_prose_only "$INTERRUPT_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  interrupt_lines=$(md_prose_only "$INTERRUPT_DOC" | wc -l | tr -d ' ')
  interrupt_raw=$(wc -l < "$INTERRUPT_DOC" | tr -d ' ')
  set -e
  FRESH_DOC="$WORKDIR/consumer-truth-fresh-list.md"
  cat > "$FRESH_DOC" <<'FRESH_EOF'
# Doc

- outer item mentioning #111
2)    a fresh list, since this marker is left of that item

      Continuation of the fresh item mentioning #222.

- another outer item mentioning #333
-
      echo "#444 is code"

And a bare #555 in prose is.
FRESH_EOF
  set +e
  fresh_hits=$(md_prose_only "$FRESH_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  if [ "$interrupt_hits" != "9,11,17," ]; then
    fail "Case 57: expected lines 9,11,17 flagged (a non-1 ordered marker and an empty marker cannot interrupt a paragraph, so the code after each is excluded), got '$interrupt_hits'"
  elif [ "$interrupt_lines" != "$interrupt_raw" ]; then
    fail "Case 57: md_prose_only must emit one line per input line, got $interrupt_lines for $interrupt_raw"
  elif [ "$fresh_hits" != "3,6,8,12," ]; then
    fail "Case 57: expected lines 3,6,8,12 flagged (a marker left of the open paragraph starts a fresh list, so its prose is still scanned), got '$fresh_hits'"
  else
    pass "Case 57: the paragraph-interruption rules bind markers inside the open block and only there"
  fi

  # Case 58: an ordered marker stops at nine digits.
  #
  # Every ordered marker in cases 41-50 is one or two digits, so all of
  # them pass under a pattern that accepts an unbounded digit run.
  # CommonMark caps the marker at nine digits, and a longer run is not a
  # marker at all. Line 6 of the first document is such a run: it is a
  # lazy continuation of the paragraph opened on line 5, and treating it
  # as a marker pops the real item at 6 and installs a phantom at 16 in
  # its place. Case 53 then closes the phantom at the next blank and
  # leaves the stack empty, so line 8 — which markdown-it-py in
  # commonmark mode renders as a second paragraph inside that item — is
  # four columns past nothing, blanked as code, and its `#222` ships
  # unflagged. That is the UNDER-reporting direction this parser must
  # never take.
  #
  # The second document is the boundary the cap must not overrun. Nine
  # digits IS a marker, so the item opened on line 3 has its content
  # indent at 11 and the fourteen-column line 5 is its prose. Reject it
  # and that line is measured against the document instead, four columns
  # in, and its `#222` is blanked the same way.
  DIGITS_DOC="$WORKDIR/consumer-truth-long-marker.md"
  cat > "$DIGITS_DOC" <<'DIGITS_EOF'
# Doc

- a

    - b mentioning #111
    1234567890. continuation

      Prose at the inner content column mentioning #222.
DIGITS_EOF
  set +e
  digits_hits=$(md_prose_only "$DIGITS_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  digits_lines=$(md_prose_only "$DIGITS_DOC" | wc -l | tr -d ' ')
  digits_raw=$(wc -l < "$DIGITS_DOC" | tr -d ' ')
  set -e
  NINE_DOC="$WORKDIR/consumer-truth-nine-digit-marker.md"
  cat > "$NINE_DOC" <<'NINE_EOF'
# Doc

123456789. an item mentioning #111

              Prose in that item mentioning #222.
NINE_EOF
  set +e
  nine_hits=$(md_prose_only "$NINE_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  if [ "$digits_hits" != "5,8," ]; then
    fail "Case 58: expected lines 5,8 flagged (a ten-digit run is not a marker, so the real item stays open), got '$digits_hits'"
  elif [ "$digits_lines" != "$digits_raw" ]; then
    fail "Case 58: md_prose_only must emit one line per input line, got $digits_lines for $digits_raw"
  elif [ "$nine_hits" != "3,5," ]; then
    fail "Case 58: expected lines 3,5 flagged (nine digits is still a marker, so its content indent is 11), got '$nine_hits'"
  else
    pass "Case 58: an ordered marker is capped at nine digits, so a longer run cannot install a phantom container"
  fi

  # Case 59: a BLOCK QUOTE is a container too.
  #
  # Cases 56 and 57 pin the lazy-continuation rules against LIST
  # containers, which the parser keeps on a stack, and both are written
  # as `ind >= list_indent`. A block quote holds paragraphs just as well
  # and is on no stack at all, so at top level inside one that test is
  # trivially true — both numbers are zero — and every fixture above
  # still passes with the rules silently switched off.
  #
  # The first document is the setext half. A setext underline may not be
  # a LAZY continuation line, so the `===` on line 4 underlines nothing
  # and the quoted paragraph runs on through line 5. Read it as an
  # underline and the paragraph closes, line 5 is four columns past the
  # document, and its `#222` is blanked as code and ships to every
  # consumer unflagged — the UNDER-reporting direction this parser must
  # never take. A bare `-` in place of the `===` does the same.
  #
  # The second document is the marker half, off the same miscount. A
  # marker outside the quote holding the paragraph interrupts nothing:
  # it ends the quote and opens its list against the DOCUMENT. So `-` on
  # line 4 opens an empty item and `2.` on line 10 opens a list starting
  # at two, neither of which either shape may do under a paragraph of
  # its own block. Refuse those containers and lines 7 and 12 are
  # measured against the document instead and blanked with their refs
  # inside.
  #
  # The third document is the limit on all of it, and it runs the other
  # way. A quote marker with nothing after it is a BLANK line inside the
  # quote: it closes the paragraph there, and it closes any paragraph
  # the quote interrupted on its way in. So line 6 IS a real underline
  # and line 11 continues nothing. Holding the quote over a paragraph
  # that has already ended emits lines 7 and 11 as prose and fails a
  # required check on a `#NN` that is code.
  #
  # Every classification here is markdown-it-py in commonmark mode,
  # which renders lines 3-5 of the first document as one `<p>` inside a
  # `<blockquote>`, lines 5 and 7 and lines 10 and 12 of the second as
  # the two paragraphs of an `<li>` apiece, and lines 7 and 11 of the
  # third inside `<pre><code>`.
  QUOTE_DOC="$WORKDIR/consumer-truth-lazy-quote.md"
  cat > "$QUOTE_DOC" <<'QUOTE_EOF'
# Doc

> Canonical source: the review policy, mentioning #111.
===
    Then fix #222 before merging.

And a bare #333 in prose is.
QUOTE_EOF
  set +e
  quote_hits=$(md_prose_only "$QUOTE_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  quote_lines=$(md_prose_only "$QUOTE_DOC" | wc -l | tr -d ' ')
  quote_raw=$(wc -l < "$QUOTE_DOC" | tr -d ' ')
  set -e
  QLIST_DOC="$WORKDIR/consumer-truth-quote-marker.md"
  cat > "$QLIST_DOC" <<'QLIST_EOF'
# Doc

> A quote mentioning #111.
-
    An item paragraph mentioning #222.

    A second paragraph of that same item, mentioning #333.

> Another quote mentioning #444.
2. A list starting at two, mentioning #555.

    Its continuation, mentioning #666.
QLIST_EOF
  set +e
  qlist_hits=$(md_prose_only "$QLIST_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  QBLANK_DOC="$WORKDIR/consumer-truth-quote-blank.md"
  cat > "$QBLANK_DOC" <<'QBLANK_EOF'
# Doc

> A quote mentioning #111.
>
A real heading, since the quote closed the paragraph inside it
===
    echo "#222 is code"

Prose the empty quote interrupts, mentioning #333.
>
    echo "#444 is code"

And a bare #555 in prose is.
QBLANK_EOF
  set +e
  qblank_hits=$(md_prose_only "$QBLANK_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  set -e
  if [ "$quote_hits" != "3,5,7," ]; then
    fail "Case 59: expected lines 3,5,7 flagged (a setext underline cannot lazily continue a quoted paragraph, so the paragraph runs on), got '$quote_hits'"
  elif [ "$quote_lines" != "$quote_raw" ]; then
    fail "Case 59: md_prose_only must emit one line per input line, got $quote_lines for $quote_raw"
  elif [ "$qlist_hits" != "3,5,7,9,10,12," ]; then
    fail "Case 59: expected lines 3,5,7,9,10,12 flagged (a marker outside the quote interrupts nothing, so it opens its container), got '$qlist_hits'"
  elif [ "$qblank_hits" != "3,9,13," ]; then
    fail "Case 59: expected lines 3,9,13 flagged (a quote marker with nothing after it leaves no paragraph open, so the code after it is excluded), got '$qblank_hits'"
  else
    pass "Case 59: the lazy-continuation rules follow block quotes as well as lists, so a quoted paragraph keeps its prose and a closed one is not held open"
  fi

  # Case 60: a FENCE delimiter is bounded by the container too.
  #
  # Every other four-column allowance in the parser became relative to
  # the open container; the fence delimiter kept an absolute `ind < 4`,
  # and the two disagree as soon as a list item is indented that far. A
  # `10. ` marker puts its content indent at exactly four, so the
  # ```bash opener on line 4 was four columns in, was refused as a
  # delimiter, and no fence ever opened — the whole body of the block,
  # `#111` included, was emitted as prose. That is the false-positive
  # direction on a required check, and it is not hypothetical: it is
  # what this parser did to a real tracked doc.
  #
  # The second half pins the other end, which the tracked corpus does
  # NOT cover and so cannot defend. Relative must not become unbounded:
  # six columns in, under a `- ` item whose content indent is two, the
  # ``` on line 17 is indented CODE, not a delimiter. Opening a fence
  # there is the UNDER-reporting direction — nothing closes it, and the
  # real prose ref on line 20 is swallowed to end of file.
  FBASE_DOC="$WORKDIR/consumer-truth-fence-base.md"
  cat > "$FBASE_DOC" <<'FBASE_EOF'
# Doc

10. **Commit and test:**
    ```bash
    git commit -m "closes #111"
    ```
11. A bare #222 in item prose is real.

A top-level fence:

```bash
echo "#333 is fenced"
```

- item

      ```
      #444 sits in indented code, not a fence

A bare #555 in prose is real.
FBASE_EOF
  set +e
  fbase_hits=$(md_prose_only "$FBASE_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  fbase_lines=$(md_prose_only "$FBASE_DOC" | wc -l | tr -d ' ')
  fbase_raw=$(wc -l < "$FBASE_DOC" | tr -d ' ')
  set -e
  if [ "$fbase_hits" != "7,20," ]; then
    fail "Case 60: expected lines 7,20 flagged (a fence opens at the item content indent; a delimiter four columns past it is indented code), got '$fbase_hits'"
  elif [ "$fbase_lines" != "$fbase_raw" ]; then
    fail "Case 60: md_prose_only must emit one line per input line, got $fbase_lines for $fbase_raw"
  else
    pass "Case 60: a fence delimiter is bounded four columns past its container, so an indented fence opens and an over-indented one stays code"
  fi

  # Case 61: a fence ENDS with the container it opened in.
  #
  # Case 60 made the delimiter allowance relative to the open container
  # and stopped there, so the CLOSING test recomputed the allowance from
  # the closing line. A fenced code block has no lazy continuation: a
  # non-blank line left of the content indent of the item is not part of
  # the item, so CommonMark ends the item there and the unclosed fence
  # with it. Recomputing instead accepts an outdented delimiter as the
  # closer of the inner fence, and every fence after it is off by one.
  #
  # All three halves are UNDER-reporting, the direction this parser must
  # never take, and all three come from markdown-it-py in commonmark mode:
  # it renders lines 4-8, 11-12 and 16-17 inside `<pre><code>` and lines
  # 13 and 20 inside `<p>`.
  #
  # Lines 3-8 are the inverted parity. Line 6 outdents out of the `10. `
  # item, so it ends both the item and the fence and then OPENS a
  # top-level fence, which line 8 closes. Reading it as the closer of the
  # inner fence swaps the two: the fenced `#222` on line 7 is scanned
  # (harmless on its own) and the real prose after line 8 is blanked
  # instead — the swap, not the over-scan, is the damage.
  #
  # Lines 10-13 are the plainer shape, and the one a tracked doc is far
  # likelier to hold: nothing closes the fence at all, so line 13 and
  # every line after it was swallowed to end of file with `#444` inside.
  #
  # Lines 15-20 pin the ORDER of the close against the info-string rule
  # from case 49. Line 18 ends the item and the fence, and a backtick
  # opener carrying a backtick in its info string cannot open a new one,
  # so it is a paragraph and `#666` on line 20 is prose. Closing the
  # fence after that rule is applied leaves it open on a line CommonMark
  # says is not a delimiter at all, and `#666` ships unflagged again.
  FEND_DOC="$WORKDIR/consumer-truth-fence-end.md"
  cat > "$FEND_DOC" <<'FEND_EOF'
# Doc

10. item
    ```
    #111 is fenced
```
#222 is fenced too, at the top level
```

- item
  ```
  #333 is fenced
A bare #444 in prose is real.

- item
  ```
  #555 is fenced
```a`b

A bare #666 in prose is real.
FEND_EOF
  set +e
  fend_hits=$(md_prose_only "$FEND_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  fend_lines=$(md_prose_only "$FEND_DOC" | wc -l | tr -d ' ')
  fend_raw=$(wc -l < "$FEND_DOC" | tr -d ' ')
  set -e
  if [ "$fend_hits" != "13,20," ]; then
    fail "Case 61: expected lines 13,20 flagged (a fence ends with the container it opened in, so an outdented delimiter opens rather than closes), got '$fend_hits'"
  elif [ "$fend_lines" != "$fend_raw" ]; then
    fail "Case 61: md_prose_only must emit one line per input line, got $fend_lines for $fend_raw"
  else
    pass "Case 61: a fence ends with the container it opened in, so no outdented line inverts the parity or swallows the prose after it"
  fi

  # Case 62: a fence OPENER closes the containers it outdents out of.
  #
  # The other end of case 61, and the reason `fence_base` can be trusted
  # at all. A fence is no more a lazy continuation than a heading is, so
  # the ``` on line 4 ends the `10. ` item opened on line 3 and opens a
  # fence against the DOCUMENT. A delimiter line returns before the pop
  # loop, so without popping here the item stays on the stack for the
  # whole block and every later `container_base` is measured from a
  # container CommonMark has already closed.
  #
  # Line 6 is where that shows. CommonMark lets a closer sit at most three
  # spaces past the container of the OPENER — column zero here — so a
  # four-space delimiter is CONTENT, which is why markdown-it-py in
  # commonmark mode renders lines 4-8 inside one `<pre><code>` and only
  # line 10 inside a `<p>`. Measured from the stale item at 4 it is three
  # columns in and reads as the closer instead, and the parity inverts
  # exactly as in case 61: the still-fenced `#222` on line 7 is scanned,
  # line 8 opens a fence rather than closing one, and the real `#333` on
  # line 10 is blanked — the UNDER-reporting direction.
  #
  # The pop uses the same predicate as the block-boundary loop, so a
  # delimiter AT the container content indent — every fence in case 60 —
  # pops nothing, which is what leaves case 60 unmoved.
  FOPEN_DOC="$WORKDIR/consumer-truth-fence-open.md"
  cat > "$FOPEN_DOC" <<'FOPEN_EOF'
# Doc

10. item
```
    #111 is fenced, and the four-space delimiter below is content
    ```
    #222 is still fenced
```

A bare #333 in prose is real.
FOPEN_EOF
  set +e
  fopen_hits=$(md_prose_only "$FOPEN_DOC" | grep -nE "$BARE_ISSUE_RE" | cut -d: -f1 | tr '\n' ',')
  fopen_lines=$(md_prose_only "$FOPEN_DOC" | wc -l | tr -d ' ')
  fopen_raw=$(wc -l < "$FOPEN_DOC" | tr -d ' ')
  set -e
  if [ "$fopen_hits" != "10," ]; then
    fail "Case 62: expected line 10 flagged (a fence opener closes the item, so the four-space delimiter on line 6 is content), got '$fopen_hits'"
  elif [ "$fopen_lines" != "$fopen_raw" ]; then
    fail "Case 62: md_prose_only must emit one line per input line, got $fopen_lines for $fopen_raw"
  else
    pass "Case 62: a fence opener closes the containers it outdents out of, so its closer is measured from the container it really opened in"
  fi

else
  echo "SKIP: Cases 36-62 need a mergepath checkout (live manifest + sync-to-downstream.sh)"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_sync_manifest: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_sync_manifest: PASS ($TOTAL tests)"
exit 0
