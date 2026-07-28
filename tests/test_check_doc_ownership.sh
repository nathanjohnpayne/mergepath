#!/usr/bin/env bash
# tests/test_check_doc_ownership.sh
#
# Unit tests for scripts/ci/check_doc_ownership — the exhaustive
# docs/agents/ ownership inventory validator added in #780.
#
# Pattern matches tests/test_check_sync_manifest.sh — fixture manifests
# plus a fixture repo tree written to a scratch dir, the check invoked
# via the MERGEPATH_MANIFEST_PATH / MERGEPATH_REPO_ROOT env overrides,
# assertions on exit code + diagnostic substring.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_doc_ownership"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-doc-ownership-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a fixture repo tree and run the check against it.
#
# Args:
#   $1 = manifest YAML content
#   $2 = newline-separated repo-relative paths to materialize (trailing
#        slash → directory, otherwise an empty file)
#   $3 = optional: "no-marker" to omit scripts/sync-to-downstream.sh, so
#        the fixture looks like a CONSUMER checkout instead of the hub
run_with_fixture() {
  local manifest_content="$1" paths="$2" marker_mode="${3:-marker}"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  # The consumer-vs-hub disambiguation keys off this marker file.
  if [ "$marker_mode" != "no-marker" ]; then
    mkdir -p "$fix/scripts"
    : > "$fix/scripts/sync-to-downstream.sh"
  fi
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

# Same as run_with_fixture, but ALSO writes a stub scripts/ci/check_sync_manifest
# carrying an IDENTITY_DOCS_DENYLIST array, so the check-9 drift guard has
# something to read.
run_with_denylist() {
  local manifest_content="$1" paths="$2" denylist_body="$3"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  mkdir -p "$fix/scripts/ci"
  : > "$fix/scripts/sync-to-downstream.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'IDENTITY_DOCS_DENYLIST=('
    printf '%s\n' "$denylist_body"
    echo ')'
  } > "$fix/scripts/ci/check_sync_manifest"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

MIN_HEADER='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
'

# --- Case 1: baseline — one doc per class, all consistent -----------
MANIFEST_OK="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/local.md
    class: per-repo-owned
  - path: docs/agents/hub.md
    class: hub-only
"
PATHS_OK="docs/agents/shared.md
docs/agents/local.md
docs/agents/hub.md"
set +e
out=$(run_with_fixture "$MANIFEST_OK" "$PATHS_OK"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_doc_ownership: PASS (3 docs/agents doc"; then
  pass "Case 1: one doc per class, canonical backed by a paths: entry"
else
  fail "Case 1 unexpected (rc=$rc): $out"
fi

# --- Case 2: ZERO classes — an undeclared doc on disk ---------------
# The headline requirement: a docs/agents/*.md that belongs to no class
# must fail.
MANIFEST_ZERO="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
PATHS_ZERO="docs/agents/local.md
docs/agents/orphan.md"
set +e
out=$(run_with_fixture "$MANIFEST_ZERO" "$PATHS_ZERO"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "'docs/agents/orphan.md' has NO ownership class"; then
  pass "Case 2: unclassified doc on disk fails closed (zero classes)"
else
  fail "Case 2 unexpected (rc=$rc): $out"
fi

# --- Case 3: MORE THAN ONE class — the same path declared twice -----
MANIFEST_DUP="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
  - path: docs/agents/local.md
    class: hub-only
"
PATHS_DUP="docs/agents/local.md"
set +e
out=$(run_with_fixture "$MANIFEST_DUP" "$PATHS_DUP"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "is declared more than once in doc_ownership"; then
  pass "Case 3: duplicate declaration fails closed (more than one class)"
else
  fail "Case 3 unexpected (rc=$rc): $out"
fi

# --- Case 2b: nested docs are part of the exhaustive inventory ------
MANIFEST_NESTED_ZERO="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_NESTED_ZERO" "$(printf 'docs/agents/local.md\ndocs/agents/security/rules.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "'docs/agents/security/rules.md' has NO ownership class"; then
  pass "Case 2b: unclassified nested agent doc fails closed"
else
  fail "Case 2b unexpected (rc=$rc): $out"
fi

# --- Case 3b: duplicate with the SAME class still fails -------------
# Two agreeing entries are an ambiguity waiting to diverge, not a no-op.
MANIFEST_DUP_SAME="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_DUP_SAME" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "is declared more than once in doc_ownership"; then
  pass "Case 3b: duplicate with an identical class still fails closed"
else
  fail "Case 3b unexpected (rc=$rc): $out"
fi

# --- Case 4: unknown class value ------------------------------------
MANIFEST_BADCLASS="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: bootstrap-seeded
"
set +e
out=$(run_with_fixture "$MANIFEST_BADCLASS" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has class 'bootstrap-seeded' — must be exactly one of"; then
  pass "Case 4: unknown class ('bootstrap-seeded' is delivery, not ownership) fails closed"
else
  fail "Case 4 unexpected (rc=$rc): $out"
fi

# --- Case 5: stale entry for a doc that no longer exists ------------
MANIFEST_STALE="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/deleted.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_STALE" "docs/agents/"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "but that file does not exist in this repo"; then
  pass "Case 5: stale entry for a deleted doc fails closed"
else
  fail "Case 5 unexpected (rc=$rc): $out"
fi

# --- Case 6: canonical class with NO paths: entry (unbacked) --------
MANIFEST_UNBACKED="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
"
set +e
out=$(run_with_fixture "$MANIFEST_UNBACKED" "docs/agents/shared.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has no 'type: canonical' paths entry"; then
  pass "Case 6: unbacked canonical claim fails closed"
else
  fail "Case 6 unexpected (rc=$rc): $out"
fi

# --- Case 7: unbacked canonical is OK with pending_manifest + note --
MANIFEST_PENDING="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
    pending_manifest: true
    note: manifest entry deferred to the class audit
"
set +e
out=$(run_with_fixture "$MANIFEST_PENDING" "docs/agents/shared.md"); rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 7: pending_manifest + note records the debt and passes"
else
  fail "Case 7 unexpected (rc=$rc): $out"
fi

# --- Case 6b: subset propagation cannot back canonical ownership ----
MANIFEST_SUBSET_CANONICAL="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: [example]
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
"
set +e
out=$(run_with_fixture "$MANIFEST_SUBSET_CANONICAL" "docs/agents/shared.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has no 'type: canonical' paths entry with 'consumers: all'"; then
  pass "Case 6b: subset-only path cannot back a fleet-wide canonical doc"
else
  fail "Case 6b unexpected (rc=$rc): $out"
fi

# --- Case 6c: backing follows the effective destination -------------
MANIFEST_CANONICAL_WRONG_DEST="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    dest: docs/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
"
set +e
out=$(run_with_fixture "$MANIFEST_CANONICAL_WRONG_DEST" "$(printf 'docs/agents/shared.md\ndocs/shared.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has no 'type: canonical' paths entry with 'consumers: all'"; then
  pass "Case 6c: canonical source remapped elsewhere does not back the owned destination"
else
  fail "Case 6c unexpected (rc=$rc): $out"
fi

# --- Case 7a2: multiline pending note stays a single ownership row ---
MANIFEST_PENDING_MULTILINE="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
    pending_manifest: true
    note: |
      first paragraph

      second paragraph
"
set +e
out=$(run_with_fixture "$MANIFEST_PENDING_MULTILINE" "docs/agents/shared.md"); rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 7a2: multiline pending_manifest note is parsed as one row"
else
  fail "Case 7a2 unexpected (rc=$rc): $out"
fi

# --- Case 7b: pending_manifest WITHOUT a note fails ------------------
MANIFEST_PENDING_NONOTE="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
    pending_manifest: true
"
set +e
out=$(run_with_fixture "$MANIFEST_PENDING_NONOTE" "docs/agents/shared.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "sets pending_manifest: true without a 'note:'"; then
  pass "Case 7b: pending_manifest without a note fails closed"
else
  fail "Case 7b unexpected (rc=$rc): $out"
fi

# --- Case 7c: pending_manifest on a non-canonical class fails -------
MANIFEST_PENDING_WRONGCLASS="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
    pending_manifest: true
    note: nonsense
"
set +e
out=$(run_with_fixture "$MANIFEST_PENDING_WRONGCLASS" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "sets pending_manifest: true with class 'per-repo-owned'"; then
  pass "Case 7c: pending_manifest outside class canonical fails closed"
else
  fail "Case 7c unexpected (rc=$rc): $out"
fi

# --- Case 8: per-repo-owned doc verbatim-mirrored (direct) ----------
# The #744 clobber invariant, extended to the full inventory.
MANIFEST_CLOBBER="$MIN_HEADER
paths:
  - path: docs/agents/local.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_CLOBBER" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "VERBATIM-mirrored by a canonical/kit manifest entry (direct)"; then
  pass "Case 8: per-repo-owned doc with a canonical paths: entry fails closed"
else
  fail "Case 8 unexpected (rc=$rc): $out"
fi

# --- Case 8b: hub-only doc swept up by a KIT directory --------------
MANIFEST_KIT="$MIN_HEADER
paths:
  - path: docs/agents/
    type: kit
    consumers: all
doc_ownership:
  - path: docs/agents/hub.md
    class: hub-only
"
set +e
out=$(run_with_fixture "$MANIFEST_KIT" "docs/agents/hub.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "kit-contains(docs/agents)"; then
  pass "Case 8b: hub-only doc inside a kit directory fails closed"
else
  fail "Case 8b unexpected (rc=$rc): $out"
fi

# --- Case 8c: alternate spelling ('./docs/agents/local.md') ---------
# Normalization must defeat the raw-string bypass, same as
# check_sync_manifest's mp_normalize_path.
MANIFEST_DOTSLASH="$MIN_HEADER
paths:
  - path: ./docs/agents/local.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_DOTSLASH" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "VERBATIM-mirrored"; then
  pass "Case 8c: './'-prefixed paths: entry still trips the clobber guard"
else
  fail "Case 8c unexpected (rc=$rc): $out"
fi

# --- Case 8d: a `dest:` remap onto a per-repo-owned doc -------------
MANIFEST_DEST="$MIN_HEADER
paths:
  - path: examples/local-template.md
    dest: docs/agents/local.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_DEST" "$(printf 'docs/agents/local.md\nexamples/local-template.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "VERBATIM-mirrored"; then
  pass "Case 8d: canonical entry whose dest: is a per-repo-owned doc fails closed"
else
  fail "Case 8d unexpected (rc=$rc): $out"
fi

# --- Case 8e: CONTROL — a templated entry is NOT a verbatim mirror --
# `type: templated` is the documented escape hatch (rendered per-consumer
# from facts), so it must NOT trip the clobber guard.
MANIFEST_TEMPLATED="$MIN_HEADER
paths:
  - path: docs/agents/local.md
    source: examples/local-template.md
    type: templated
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_TEMPLATED" "$(printf 'docs/agents/local.md\nexamples/local-template.md')"); rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 8e: templated entry does not trip the verbatim clobber guard (control)"
else
  fail "Case 8e unexpected (rc=$rc): $out"
fi

# --- Case 8f: canonical ownership requires a canonical paths entry --
# A same-path templated entry does not back a verbatim canonical class.
MANIFEST_CANONICAL_TEMPLATED="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    source: examples/shared-template.md
    type: templated
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
"
set +e
out=$(run_with_fixture "$MANIFEST_CANONICAL_TEMPLATED" "$(printf 'docs/agents/shared.md\nexamples/shared-template.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has no 'type: canonical' paths entry"; then
  pass "Case 8f: canonical doc is not backed by a templated paths entry"
else
  fail "Case 8f unexpected (rc=$rc): $out"
fi

# --- Case 8e2: a default self-sourced template still clobbers -------
MANIFEST_TEMPLATED_SELF_DEFAULT="$MIN_HEADER
paths:
  - path: docs/agents/local.md
    type: templated
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_TEMPLATED_SELF_DEFAULT" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "effective source and destination of a templated manifest entry"; then
  pass "Case 8e2: default self-sourced template cannot clobber a per-repo doc"
else
  fail "Case 8e2 unexpected (rc=$rc): $out"
fi

# --- Case 8e3: explicit equivalent self-source is normalized --------
MANIFEST_TEMPLATED_SELF_EXPLICIT="$MIN_HEADER
paths:
  - path: ./docs/agents/local.md
    dest: docs/agents/local.md
    source: ./docs/agents/local.md
    type: templated
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: hub-only
"
set +e
out=$(run_with_fixture "$MANIFEST_TEMPLATED_SELF_EXPLICIT" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "effective source and destination of a templated manifest entry"; then
  pass "Case 8e3: normalized explicit self-source cannot clobber a hub-only doc"
else
  fail "Case 8e3 unexpected (rc=$rc): $out"
fi

# --- Case 9: entry outside the docs/agents/ scope -------------------
MANIFEST_OUTSCOPE="$MIN_HEADER
paths: []
doc_ownership:
  - path: README.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_OUTSCOPE" "README.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "outside the inventory's scope"; then
  pass "Case 9: a non-docs/agents path in the inventory fails closed"
else
  fail "Case 9 unexpected (rc=$rc): $out"
fi

# --- Case 9b: parent traversal is rejected before filesystem probes --
MANIFEST_PARENT_TRAVERSAL="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/../sync-overrides.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_PARENT_TRAVERSAL" "docs/sync-overrides.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "absolute paths and '..' segments are not allowed"; then
  pass "Case 9b: parent traversal in ownership path fails closed"
else
  fail "Case 9b unexpected (rc=$rc): $out"
fi

# --- Case 9c: absolute paths are rejected before scope checks -------
MANIFEST_ABSOLUTE="$MIN_HEADER
paths: []
doc_ownership:
  - path: /docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_ABSOLUTE" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "absolute paths and '..' segments are not allowed"; then
  pass "Case 9c: absolute ownership path fails closed"
else
  fail "Case 9c unexpected (rc=$rc): $out"
fi

# --- Case 10: missing doc_ownership block ---------------------------
MANIFEST_NOBLOCK="$MIN_HEADER
paths: []
"
set +e
out=$(run_with_fixture "$MANIFEST_NOBLOCK" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "has no 'doc_ownership:' block"; then
  pass "Case 10: a manifest with no doc_ownership block fails closed"
else
  fail "Case 10 unexpected (rc=$rc): $out"
fi

# --- Case 10c: empty mapping row is malformed, not skipped ----------
MANIFEST_EMPTY_ENTRY="$MIN_HEADER
paths: []
doc_ownership:
  - {}
"
set +e
out=$(run_with_fixture "$MANIFEST_EMPTY_ENTRY" "docs/agents/"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "doc_ownership entry has an empty 'path'"; then
  pass "Case 10c: empty doc_ownership mapping fails closed"
else
  fail "Case 10c unexpected (rc=$rc): $out"
fi

# --- Case 10b: doc_ownership present but a SCALAR -------------------
# Fail-open guard: `.doc_ownership[]` over a scalar iterates garbage
# while yq still exits 0, so the seq-tag assert has to come first.
MANIFEST_SCALAR="$MIN_HEADER
paths: []
doc_ownership: oops
"
set +e
out=$(run_with_fixture "$MANIFEST_SCALAR" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "must be a list (got YAML tag"; then
  pass "Case 10b: scalar doc_ownership fails closed instead of iterating garbage"
else
  fail "Case 10b unexpected (rc=$rc): $out"
fi

# --- Case 11: consumer checkout SKIPs -------------------------------
# The wrapper ships via the scripts/ci/ kit and runs in every consumer's
# repo_lint.yml; the manifest is hub-only, so a consumer must no-op.
set +e
out=$(MERGEPATH_MANIFEST_PATH="$WORKDIR/nonexistent-manifest.yml" \
      MERGEPATH_REPO_ROOT="$WORKDIR/nonexistent-root" bash "$CHECK" 2>&1); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_doc_ownership: SKIP"; then
  pass "Case 11: consumer checkout (no manifest, no orchestrator marker) SKIPs"
else
  fail "Case 11 unexpected (rc=$rc): $out"
fi

# --- Case 11b: hub checkout with a MISSING manifest FAILS -----------
HUBFIX="$(mktemp -d "$WORKDIR/hubfix.XXXXXX")"
mkdir -p "$HUBFIX/scripts"
: > "$HUBFIX/scripts/sync-to-downstream.sh"
set +e
out=$(MERGEPATH_MANIFEST_PATH="$HUBFIX/gone.yml" MERGEPATH_REPO_ROOT="$HUBFIX" bash "$CHECK" 2>&1); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "must not be deleted/renamed"; then
  pass "Case 11b: hub checkout with a deleted manifest fails closed"
else
  fail "Case 11b unexpected (rc=$rc): $out"
fi

# --- Case 12: denylist drift guard ----------------------------------
# A doc on check_sync_manifest's IDENTITY_DOCS_DENYLIST classified
# canonical here is a self-contradiction: check 7 wants a paths: entry
# that check_sync_manifest check 8 would refuse.
MANIFEST_DRIFT="$MIN_HEADER
paths: []
doc_ownership:
  - path: ./docs/agents/identity.md
    class: canonical
    pending_manifest: true
    note: deliberately contradictory fixture
"
set +e
out=$(run_with_denylist "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  "  README.md
  docs/agents/identity.md")
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12: denylisted doc classified canonical fails closed after path normalization (drift guard)"
else
  fail "Case 12 unexpected (rc=$rc): $out"
fi

# --- Case 12b: CONTROL — denylisted doc classified per-repo-owned ---
MANIFEST_DRIFT_OK="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/identity.md
    class: per-repo-owned
"
set +e
out=$(run_with_denylist "$MANIFEST_DRIFT_OK" "docs/agents/identity.md" \
  "  README.md
  docs/agents/identity.md")
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 12b: denylisted doc classified per-repo-owned passes (control)"
else
  fail "Case 12b unexpected (rc=$rc): $out"
fi

# --- Case 13: LIVE manifest — the real repo must be consistent ------
# Guards against the inventory and the live tree drifting apart between
# fixture-only runs. Skipped when the manifest is absent (consumer).
#
# MERGEPATH_MANIFEST_PATH is set EXPLICITLY to the live manifest — same
# data, but it also tells the check "a harness is driving me", which
# suppresses its own suite re-run. Without it this case would re-enter
# this file and recurse.
if [ -f "$ROOT/.mergepath-sync.yml" ]; then
  set +e
  out=$(MERGEPATH_MANIFEST_PATH="$ROOT/.mergepath-sync.yml" \
        MERGEPATH_REPO_ROOT="$ROOT" bash "$CHECK" 2>&1); rc=$?
  set -e
  if [ "$rc" = "0" ] && echo "$out" | grep -q "check_doc_ownership: PASS"; then
    pass "Case 13: live .mergepath-sync.yml classifies every docs/agents doc"
  else
    fail "Case 13 unexpected (rc=$rc): $out"
  fi
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_doc_ownership: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_doc_ownership: PASS ($TOTAL tests)"
exit 0
