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

# Same as run_with_fixture, but the fixture files carry CONTENT — check
# 10 reads canonical docs looking for hub-only references, so an empty
# file proves nothing.
#
# One row per line, so a body needing MULTIPLE lines (a reference-style
# link definition, which must start its own line) writes them as literal
# `\n` escapes — `printf '%b'` expands them. A raw newline inside a body
# would be read as the next ROW and mis-parsed as a path.
#
# Args:
#   $1 = manifest YAML content
#   $2 = newline-separated "<repo-relative path>|<file content>" rows
run_with_doc_bodies() {
  local manifest_content="$1" doc_rows="$2"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  mkdir -p "$fix/scripts"
  : > "$fix/scripts/sync-to-downstream.sh"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local p="${row%%|*}" body="${row#*|}"
    mkdir -p "$(dirname "$fix/$p")"
    printf '%b\n' "$body" > "$fix/$p"
  done <<< "$doc_rows"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

# Same as run_with_fixture, but ALSO writes a stub scripts/ci/check_sync_manifest
# whose CONTENTS are supplied verbatim ($3), so a case can pin the exact Bash
# SHAPE of the IDENTITY_DOCS_DENYLIST declaration — a one-line array, an
# indented closing paren, code living after the array — and not just its body.
run_with_sibling() {
  local manifest_content="$1" paths="$2" sibling_source="$3"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  mkdir -p "$fix/scripts/ci"
  : > "$fix/scripts/sync-to-downstream.sh"
  printf '%s\n' "$sibling_source" > "$fix/scripts/ci/check_sync_manifest"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

# The common shape: the denylist BODY ($3) wrapped in the canonical
# multi-line declaration the live sibling uses today.
run_with_denylist() {
  run_with_sibling "$1" "$2" \
    "$(printf '#!/usr/bin/env bash\nIDENTITY_DOCS_DENYLIST=(\n%s\n)\n' "$3")"
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

# --- Case 2c: symlink path names are inventory entries, not files to skip ---
# `find -type f` omits symbolic links, including a tracked `*.md` link that
# has no ownership entry at all. Inventory completeness must enumerate the
# Markdown path name and reject the link explicitly.
SYMLINK_FIX="$(mktemp -d "$WORKDIR/symlink-zero.XXXXXX")"
printf '%s' "$MANIFEST_ZERO" > "$SYMLINK_FIX/manifest.yml"
mkdir -p "$SYMLINK_FIX/scripts" "$SYMLINK_FIX/docs/agents"
: > "$SYMLINK_FIX/scripts/sync-to-downstream.sh"
: > "$SYMLINK_FIX/docs/agents/local.md"
: > "$SYMLINK_FIX/outside.md"
ln -s ../../outside.md "$SYMLINK_FIX/docs/agents/orphan.md"
set +e
out=$(MERGEPATH_MANIFEST_PATH="$SYMLINK_FIX/manifest.yml" \
  MERGEPATH_REPO_ROOT="$SYMLINK_FIX" bash "$CHECK" 2>&1)
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "'docs/agents/orphan.md' is a symbolic link"; then
  pass "Case 2c: undeclared symlinked Markdown path is enumerated and rejected"
else
  fail "Case 2c unexpected (rc=$rc): $out"
fi

# A declared symlink used to pass the stale-entry test because `-f` follows
# links. Reject it before its class is admitted to the canonical/hub lists.
MANIFEST_SYMLINK_DECLARED="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
  - path: docs/agents/linked.md
    class: hub-only
"
printf '%s' "$MANIFEST_SYMLINK_DECLARED" > "$SYMLINK_FIX/manifest.yml"
ln -sfn ../../outside.md "$SYMLINK_FIX/docs/agents/linked.md"
set +e
out=$(MERGEPATH_MANIFEST_PATH="$SYMLINK_FIX/manifest.yml" \
  MERGEPATH_REPO_ROOT="$SYMLINK_FIX" bash "$CHECK" 2>&1)
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "'docs/agents/linked.md' is a symbolic link"; then
  pass "Case 2c2: declared symlink is rejected instead of accepted by -f"
else
  fail "Case 2c2 unexpected (rc=$rc): $out"
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

# A quoted scalar is truthy-looking to a string comparison but is not the
# boolean flag the manifest contract defines. It must not waive propagation.
MANIFEST_PENDING_STRING="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
    pending_manifest: \"true\"
    note: wrong YAML type must not disable propagation
"
set +e
out=$(run_with_fixture "$MANIFEST_PENDING_STRING" "docs/agents/shared.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "pending_manifest.*YAML boolean"; then
  pass "Case 7a: pending_manifest accepts only a YAML boolean"
else
  fail "Case 7a unexpected (rc=$rc): $out"
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

# --- Case 6d: canonical propagation does not support dest remaps ----
MANIFEST_CANONICAL_DEST_REMAP="$MIN_HEADER
paths:
  - path: templates/shared.md
    dest: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
"
set +e
out=$(run_with_fixture "$MANIFEST_CANONICAL_DEST_REMAP" "$(printf 'templates/shared.md\ndocs/agents/shared.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "remove the unsupported dest remap"; then
  pass "Case 6d: canonical destination remap fails closed"
else
  fail "Case 6d unexpected (rc=$rc): $out"
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

# --- Case 9d: embedded dot segments in paths entries are rejected ---
MANIFEST_EMBEDDED_DOT="$MIN_HEADER
paths:
  - path: docs/agents/./local.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/local.md
    class: per-repo-owned
"
set +e
out=$(run_with_fixture "$MANIFEST_EMBEDDED_DOT" "docs/agents/local.md"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "embedded '.'/empty segments"; then
  pass "Case 9d: embedded dot segment in a manifest path fails closed"
else
  fail "Case 9d unexpected (rc=$rc): $out"
fi

# --- Case 9e: comma paths cannot corrupt the shell membership sets --
MANIFEST_COMMA_PATH="$MIN_HEADER
paths:
  - path: docs/agents/rules.md,backup.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/rules.md,backup.md
    class: canonical
"
set +e
out=$(run_with_fixture "$MANIFEST_COMMA_PATH" "$(printf 'docs/agents/rules.md,backup.md\ndocs/agents/rules.md')"); rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "commas are also rejected"; then
  pass "Case 9e: comma-delimited path cannot corrupt ownership membership checks"
else
  fail "Case 9e unexpected (rc=$rc): $out"
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

# --- Case 12c: QUOTED denylist entries still trip the drift guard ----
# IDENTITY_DOCS_DENYLIST is Bash source, so an entry may legitimately be
# written `"docs/agents/x.md"`. A reader that trims whitespace only keeps
# the leading quote, the guard's `docs/agents/*` case stops matching, and
# a real contradiction is reported as a PASS (#785/#786). Same fixture as
# Case 12 with the entries quoted — the verdict must not change.
set +e
out=$(run_with_denylist "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '  "README.md"
  "docs/agents/identity.md"')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12c: double-quoted denylist entry still fails closed (quote stripping)"
else
  fail "Case 12c unexpected (rc=$rc): $out"
fi

# --- Case 12d: single quotes + a trailing inline comment ------------
# The other half of the real array shape: Bash allows single quotes and a
# trailing `# ...` comment on the same line. Stripping quotes alone is
# not enough — the comment leaves a dangling closing quote mid-token.
set +e
out=$(run_with_denylist "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  "  'README.md'  # repo-owned front door
  'docs/agents/identity.md'  # per-repo identity doc")
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12d: single-quoted denylist entry with a trailing comment still fails closed"
else
  fail "Case 12d unexpected (rc=$rc): $out"
fi

# --- Case 12e: CONTROL — a commented-OUT entry is not an entry -------
# The over-correction mirror of 12c/12d, and a control in the same sense
# as 12b: it passes both before and after the quote/comment fix. Its job
# is to pin the tokenizer's other edge — a `#`-prefixed line inside the
# array is Bash comment text, not an array element, so reading it as one
# would invent a denylist entry nobody wrote and fail a doc that is
# correctly classified canonical.
MANIFEST_DRIFT_COMMENTED="$MIN_HEADER
paths:
  - path: docs/agents/identity.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/identity.md
    class: canonical
"
set +e
out=$(run_with_denylist "$MANIFEST_DRIFT_COMMENTED" "docs/agents/identity.md" \
  '  "README.md"
  # "docs/agents/identity.md"  <- withdrawn, see the follow-up')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 12e: a commented-out denylist line is not read as an entry"
else
  fail "Case 12e unexpected (rc=$rc): $out"
fi

# --- Case 12f: the read STOPS at an indented closing paren ----------
# The array terminator is `)` wherever it falls on the line, not `)` in
# column 1. Keying off column 1 leaves the reader "inside" once someone
# indents the paren, and every later line of the sibling — including any
# quoted docs/agents/ path in ordinary code — becomes denylist data. That
# invents a denylist entry nobody wrote and fails a doc that is correctly
# classified canonical, so the assertion here is a PASS: identity.md is
# NOT on this denylist, it only appears after the array closed.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT_COMMENTED" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=(
  "README.md"
  )

emit_identity_hint() {
  echo "docs/agents/identity.md"
}')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 12f: an indented closing paren ends the array (no spill into later code)"
else
  fail "Case 12f unexpected (rc=$rc): $out"
fi

# --- Case 12g: a SINGLE-LINE array declaration is read --------------
# `NAME=(a b)` is ordinary Bash and the whole array can share the
# declaration line. A reader that consumes that line to detect the
# declaration and starts collecting on the NEXT one sees an empty
# denylist, and check 9 skips itself — the same silent no-op as #785,
# reached by a different route.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=("README.md" "docs/agents/identity.md")')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12g: entries on the declaration line still fail closed"
else
  fail "Case 12g unexpected (rc=$rc): $out"
fi

# --- Case 12h: CONTROL — a paren inside a comment does not close ----
# The over-correction mirror of 12f, in the same sense 12e mirrors 12c:
# now that `)` terminates the array anywhere on the line, a `)` sitting
# in a comment INSIDE the array must not end it early and silently drop
# every entry below it.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=(
  "README.md"
  # withdrawn once (see the #786 follow-up) and then restored
  "docs/agents/identity.md"
)')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12h: a closing paren inside a comment does not truncate the array"
else
  fail "Case 12h unexpected (rc=$rc): $out"
fi

# --- Case 12i: a backslash-newline continuation is ONE element ------
# Bash deletes a backslash-newline inside double quotes as much as
# outside it, so the two physical lines below are a single element
# spelling docs/agents/identity.md. A reader that resets its token at
# each newline sees two fragments instead — neither names a file, the
# existence check drops both, and the contradiction is skipped.
set +e
out=$(run_with_denylist "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '  "README.md"
  "docs/agents/iden\
tity.md"')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12i: a line-continued denylist entry is read as one element"
else
  fail "Case 12i unexpected (rc=$rc): $out"
fi

# --- Case 12j: CONTROL — over-correction mirror of 12i --------------
# Two ways a continuation-aware reader goes wrong, both landing on this
# one assertion because either would invent `docs/agents/identity.md` and
# fail a doc whose classification is correct:
#
#   * `iden\\` ends in an ESCAPED backslash, not a continuation. Bash
#     yields `docs/agents/iden\` and `tity.md` as two elements. A reader
#     that tests the raw line for a trailing backslash joins them into
#     the denied path instead. The continued line starts in column 1 on
#     purpose: Bash deletes the backslash-newline but not the next
#     line's indentation, so an indented `tity.md` would split in both
#     readings and the fixture would prove nothing.
#   * the `\` after `tity.md` IS a continuation, and it must not carry
#     the reader past the `)` on the next line — that would leave it
#     inside the array to end of file and adopt the path in the function
#     below as an entry nobody wrote.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT_COMMENTED" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=(
  docs/agents/iden\\
tity.md \
)

emit_identity_hint() {
  echo "docs/agents/identity.md"
}')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 12j: an escaped backslash is not a continuation, and a continuation does not outlive the array"
else
  fail "Case 12j unexpected (rc=$rc): $out"
fi

# --- Case 12k: a substitution does not terminate the array ----------
# `$(...)` owns its own closing paren. Treating that paren as the end of
# the array stops the read on the first element and returns the truncated
# prefix as an all-clear, so every static entry BELOW the substitution —
# here the denylisted doc itself — goes unread. The element that cannot
# be expanded is still reported, because a denylist read only in part
# must not pass for a complete one.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
sibling_helper() { echo "README.md"; }
IDENTITY_DOCS_DENYLIST=(
  $(sibling_helper)
  docs/agents/identity.md
)')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST" \
   && echo "$out" | grep -q "unexpanded substitution"; then
  pass "Case 12k: a command substitution neither ends the array nor passes silently"
else
  fail "Case 12k unexpected (rc=$rc): $out"
fi

# --- Case 12l: a later assignment REPLACES the earlier one ----------
# Bash evaluates the file top to bottom, so the effective denylist is the
# last assignment, not the first. A reader that stops after the first
# declaration misses everything a reassignment added.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=(
  "README.md"
)

IDENTITY_DOCS_DENYLIST=(
  "README.md"
  "docs/agents/identity.md"
)')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12l: entries added by a later assignment are enforced"
else
  fail "Case 12l unexpected (rc=$rc): $out"
fi

# --- Case 12m: the same rule in the OTHER direction -----------------
# The mirror of 12l, and the sharper half: reading only the first
# declaration does not merely miss entries, it keeps ENFORCING entries a
# reassignment removed — failing a doc whose classification is correct
# against the denylist Bash actually evaluates.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT_COMMENTED" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=(
  "README.md"
  "docs/agents/identity.md"
)

IDENTITY_DOCS_DENYLIST=(
  "README.md"
)')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 12m: entries dropped by a later assignment stop being enforced"
else
  fail "Case 12m unexpected (rc=$rc): $out"
fi

# --- Case 12n: `+=` appends, wherever it is indented ----------------
# The other half of "the effective value wins": `+=(...)` adds to the
# array rather than replacing it, and a reassignment is most often
# written indented inside a conditional or a function.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=("README.md")
if true; then
  IDENTITY_DOCS_DENYLIST+=("docs/agents/identity.md")
fi')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "IDENTITY_DOCS_DENYLIST"; then
  pass "Case 12n: an indented += appends to the denylist"
else
  fail "Case 12n unexpected (rc=$rc): $out"
fi

# --- Case 12o: CONTROL — an unterminated array yields NO entries ----
# The safety property behind buffering elements instead of streaming
# them: an array left open by an unbalanced quote is not a short
# denylist, it is a file Bash would refuse. The reader must publish
# nothing (so the leftover text below is never mistaken for entries) and
# say why, rather than silently reporting a clean read.
set +e
out=$(run_with_sibling "$MANIFEST_DRIFT_COMMENTED" "docs/agents/identity.md" \
  '#!/usr/bin/env bash
IDENTITY_DOCS_DENYLIST=(
  "README.md
  "docs/agents/identity.md"')
rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "never closes"; then
  pass "Case 12o: an unterminated declaration reads as no denylist, with a note"
else
  fail "Case 12o unexpected (rc=$rc): $out"
fi

# Inside Bash double quotes, backslashes before dollar and backtick quote those
# characters. They are literal filename bytes, not substitutions, and must be
# unescaped before the inventory comparison.
MANIFEST_DQ_ESCAPES="$MIN_HEADER"'
paths: []
doc_ownership:
  - path: docs/agents/$policy.md
    class: canonical
    pending_manifest: true
    note: escaped dollar filename
  - path: docs/agents/`policy`.md
    class: canonical
    pending_manifest: true
    note: escaped backtick filename
'
set +e
out=$(run_with_denylist "$MANIFEST_DQ_ESCAPES" 'docs/agents/$policy.md
docs/agents/`policy`.md' '  "docs/agents/\$policy.md"
  "docs/agents/\`policy\`.md"'); rc=$?
set -e
if [ "$rc" = "1" ] \
   && echo "$out" | grep -q "docs/agents/\$policy.md.*IDENTITY_DOCS_DENYLIST" \
   && echo "$out" | grep -q 'docs/agents/`policy`.md.*IDENTITY_DOCS_DENYLIST' \
   && ! echo "$out" | grep -q "unexpanded substitution"; then
  pass "Case 12p: double-quoted dollar/backtick escapes compare as literal denylist paths"
else
  fail "Case 12p unexpected (rc=$rc): $out"
fi

# --- Case 14: canonical doc links a HUB-ONLY doc (check 10) ---------
# The #780 consumer-truthfulness guardrail: the canonical file is
# mirrored verbatim into nine repos that will never receive the hub-only
# file, so the link 404s everywhere but here.
MANIFEST_TRUTH="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/hub.md
    class: hub-only
"
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Full procedure: `docs/agents/hub.md` § Wave audit.
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md'"; then
  pass "Case 14: canonical doc referencing a hub-only doc fails closed (consumer-truthfulness)"
else
  fail "Case 14 unexpected (rc=$rc): $out"
fi

# --- Case 14b: CONTROL — same reference as an absolute hub URL ------
# An absolute URL resolves from any repo, so it is the sanctioned way to
# point at hub-only machinery (REVIEW_POLICY.md does exactly this).
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|See [the audit](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md).
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14b: same reference as an absolute github.com URL passes (control)"
else
  fail "Case 14b unexpected (rc=$rc): $out"
fi

# --- Case 14c: CONTROL — hub-only doc may reference another ---------
# Check 10 constrains the canonical class only; two hub-only docs
# cross-referencing each other never leave the hub.
MANIFEST_TRUTH_HUBHUB="$MIN_HEADER
paths: []
doc_ownership:
  - path: docs/agents/hub.md
    class: hub-only
  - path: docs/agents/hub2.md
    class: hub-only
"
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH_HUBHUB" \
  'docs/agents/hub.md|See `docs/agents/hub2.md`.
docs/agents/hub2.md|# More hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14c: hub-only doc referencing another hub-only doc passes (control)"
else
  fail "Case 14c unexpected (rc=$rc): $out"
fi

# --- Case 14d: SIBLING-relative link spelling (check 10, pass b) -----
# Canonical and hub-only docs are siblings under docs/agents/, so the
# natural Markdown spelling carries no `docs/agents/` prefix at all. A
# literal-substring search for the repo-relative path therefore reports
# success on a link that 404s in every consumer. Check 10 resolves each
# link target against the linking doc's own directory, so all three
# sibling spellings — bare, `./`-prefixed, and a `../` round trip — are
# caught. Regression for the #797 review finding.
for spelling in 'hub.md' './hub.md' '../agents/hub.md'; do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
    "docs/agents/shared.md|Full procedure: [the audit]($spelling) § Wave audit.
docs/agents/hub.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md' by a relative Markdown link"; then
    pass "Case 14d: sibling-relative link '$spelling' to a hub-only doc fails closed"
  else
    fail "Case 14d ('$spelling') unexpected (rc=$rc): $out"
  fi
done

# --- Case 14e: reference-style definition, same gap ------------------
# `[label]: target` puts the target on its own line, well away from the
# `[label]` use site; the resolved-target pass reads both link forms.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Full procedure: [the audit] § Wave audit.\n\n[the audit]: hub.md "CodeRabbit audit"
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md' by a relative Markdown link"; then
  pass "Case 14e: reference-style link definition to a hub-only doc fails closed"
else
  fail "Case 14e unexpected (rc=$rc): $out"
fi

# --- Case 14f: CONTROL — relative links that are NOT to hub-only -----
# The resolved-target pass must not over-fire: a sibling link to another
# CANONICAL doc travels fine, an anchor has no target file, and a
# same-named file under a different directory is a different path.
MANIFEST_TRUTH_TWO_CANON="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
  - path: docs/agents/other.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/other.md
    class: canonical
  - path: docs/agents/hub.md
    class: hub-only
"
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH_TWO_CANON" \
  'docs/agents/shared.md|See [the sibling](other.md), [a section](#later), and [an unrelated file](sub/hub.md).
docs/agents/other.md|# Another canonical doc
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14f: canonical→canonical sibling links, anchors and same-name-different-dir pass (control)"
else
  fail "Case 14f unexpected (rc=$rc): $out"
fi

# --- Case 14g: CONTROL — absolute sibling-form link ------------------
# The sanctioned escape stays sanctioned when written as a Markdown link
# rather than a bare URL: pass (b) skips already-absolute targets, so it
# must not double-report what pass (a) already exempts.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|See [the audit](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md) for the posture record.
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14g: absolute github.com Markdown link to a hub-only doc passes (control)"
else
  fail "Case 14g unexpected (rc=$rc): $out"
fi

# --- Case 14h: one finding per pair, not one per spelling ------------
# A doc that spells the same broken reference BOTH ways (literal path in
# prose, sibling link in Markdown) is one defect; check 10 must report
# it once so the diagnostic count tracks defects, not spellings.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Full procedure: `docs/agents/hub.md`, also linked as [the audit](hub.md).
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
hits=$(echo "$out" | grep -c "references the hub-only doc 'docs/agents/hub.md'" || true)
if [ "$rc" = "1" ] && [ "$hits" = "1" ]; then
  pass "Case 14h: a doubly-spelled reference is reported exactly once"
else
  fail "Case 14h unexpected (rc=$rc, hits=$hits): $out"
fi

# --- Case 14i: bare mention BESIDE an absolute URL, one line ---------
# The absolute-URL escape hatch used to be applied per LINE: any line
# containing `github.com/` was dropped before the literal test. A
# sentence that spells the path both ways therefore exempted its own
# broken half, and the resolved-target pass could not recover it —
# prose and inline code are not links, so they yield no target to
# resolve. Masking each URL and re-testing the remainder scopes the
# exemption to the URL itself. Regression for the #797 review finding.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Full procedure: `docs/agents/hub.md` ([hub copy](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md)).
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md' by repo-relative path"; then
  pass "Case 14i: a bare repo-relative mention beside an absolute URL fails closed"
else
  fail "Case 14i unexpected (rc=$rc): $out"
fi

# --- Case 14j: CONTROL — the path spelled as the LINK LABEL ----------
# REVIEW_POLICY.md's real spelling of the escape hatch puts the
# repo-relative path in the label and the absolute URL in the
# destination. That link clicks through from any repo, so masking must
# take the label with the destination — otherwise the check reds the one
# idiom it tells authors to use.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Consult [`docs/agents/hub.md`](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md) before changing the config.
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14j: repo-relative path as the LABEL of an absolute link passes (control)"
else
  fail "Case 14j unexpected (rc=$rc): $out"
fi

# --- Case 14k: CONTROL — bare URL forms stay exempt ------------------
# The mask keys on the scheme, not on `github.com`, and must swallow an
# autolink and a reference definition's absolute destination as well as
# a plain inline URL.
for absolute in \
  'See <https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md>.' \
  'See [the audit][a].\n\n[a]: https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md "Audit"' \
  'Posture record: https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
    "docs/agents/shared.md|$absolute
docs/agents/hub.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "0" ]; then
    pass "Case 14k: absolute form '${absolute:0:24}...' passes (control)"
  else
    fail "Case 14k ('$absolute') unexpected (rc=$rc): $out"
  fi
done

# --- Case 14l: WRAPPED reference definition (check 10, pass b) -------
# CommonMark allows one line ending between a definition's colon and its
# destination, so
#
#     [the audit]:
#     hub.md
#
# renders as a working `<a href="hub.md">` — confirmed against
# markdown-it-py's commonmark preset, the parser
# scripts/lint-md-prose-wrap.sh uses. A same-line-only grep emitted no
# target for it, and the sibling spelling carries no `docs/agents/`
# prefix for the literal pass either, so the broken link shipped to all
# nine consumers unreported. Regression for the #797 review finding —
# indented and titled variants included, since the indentation cap and
# the first-token rule are the parts most easily broken.
for wrapped in \
  'Full procedure: [the audit] § Wave audit.\n\n[the audit]:\nhub.md' \
  'Full procedure: [the audit] § Wave audit.\n\n   [the audit]:\n     ./hub.md "CodeRabbit audit"' \
  'Full procedure: [the audit] § Wave audit.\n\n[the audit]:\n<hub.md>'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
    "docs/agents/shared.md|$wrapped
docs/agents/hub.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md' by a relative Markdown link"; then
    pass "Case 14l: wrapped reference definition to a hub-only doc fails closed"
  else
    fail "Case 14l ('$wrapped') unexpected (rc=$rc): $out"
  fi
done

# --- Case 14m: CONTROL — a blank line ENDS the definition ------------
# CommonMark allows at most one line ending after the colon, so a label
# left dangling above a blank line defines nothing and the following
# paragraph is just text. Emitting its first token as a link target
# would invent a reference the document does not make.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Prose above.\n\n[the audit]:\n\nhub.md is discussed in the hub-side runbook.\n\nMore prose.
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14m: a blank line after the label ends the definition (control)"
else
  fail "Case 14m unexpected (rc=$rc): $out"
fi

# --- Case 14n: query-bearing relative target ------------------------
# A URL query does not change which repository path the browser opens.
# Leaving it attached during comparison lets a canonical doc link to a
# hub-only sibling while evading the exact-path check.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|See [the audit](hub.md?plain=1) for details.
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md' by a relative Markdown link"; then
  pass "Case 14n: query-bearing relative link to a hub-only doc fails closed"
else
  fail "Case 14n unexpected (rc=$rc): $out"
fi

# --- Case 14o: CONTROL — absolute reference-style link --------------
# The visible label may name the repo-relative path when its reference
# definition points at an absolute hub URL, just like Case 14j's inline
# form. The destination is portable, so the label must be masked too.
for absolute_ref in \
  'Consult [docs/agents/hub.md][audit].\n\n[audit]: https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md' \
  'Consult [docs/agents/hub.md][audit].\n\n[audit]:\n<https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md>'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
    "docs/agents/shared.md|$absolute_ref
docs/agents/hub.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "0" ]; then
    pass "Case 14o: repo-relative label with an absolute reference destination passes (control)"
  else
    fail "Case 14o unexpected (rc=$rc): $out"
  fi
done

# --- Case 14p: relative reference labels remain visible -------------
# The absolute-reference mask must not hide the same visible label when
# its definition is relative; that spelling still breaks downstream.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Consult [docs/agents/hub.md][audit].\n\n[audit]: hub.md
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md'"; then
  pass "Case 14p: repo-relative label with a relative reference destination fails closed"
else
  fail "Case 14p unexpected (rc=$rc): $out"
fi

# --- Case 14q: angle-bracket destination containing spaces ----------
# CommonMark permits whitespace inside `<...>` destinations. Splitting the
# extracted body on whitespace turns this into `<hub` and misses the real file.
MANIFEST_TRUTH_SPACE="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/hub file.md
    class: hub-only
"
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH_SPACE" \
  'docs/agents/shared.md|See [the audit](<hub file.md>) for details.
docs/agents/hub file.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub file.md' by a relative Markdown link"; then
  pass "Case 14q: angle-bracket link target preserves embedded whitespace"
else
  fail "Case 14q unexpected (rc=$rc): $out"
fi

# URL percent escapes are decoded by the browser after link parsing. Compare
# the decoded path to the literal inventory filename.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH_SPACE" \
  'docs/agents/shared.md|See [the audit](hub%20file.md) for details.
docs/agents/hub file.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub file.md' by a relative Markdown link"; then
  pass "Case 14q2: percent-encoded link path is decoded before inventory comparison"
else
  fail "Case 14q2 unexpected (rc=$rc): $out"
fi

# --- Case 14r: CONTROL — protocol-relative inline destination -------
# `//host/path` is portable just like an https URL and is already skipped by
# the resolved-target pass. The literal mask must treat the inline form the
# same way, including its repo-relative visible label.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Consult [docs/agents/hub.md](//github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/hub.md).
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14r: protocol-relative absolute inline link passes (control)"
else
  fail "Case 14r unexpected (rc=$rc): $out"
fi

# --- Case 14s: CONTROL — link-shaped examples inside code -----------
# CommonMark does not render links inside inline or fenced code. Raw grep must
# not turn documentation of the prohibited spelling into a real broken link.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Inline example: `[audit](hub.md)`.\n\n```markdown\n[audit](hub.md)\n```\n
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass "Case 14s: link-shaped inline and fenced code examples are ignored"
else
  fail "Case 14s unexpected (rc=$rc): $out"
fi

# CommonMark does not let indented code interrupt an open list item or
# paragraph. These four-space lines still render links and must remain visible
# to the consumer-truthfulness scan.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|- Governance\n    - See [the audit](hub.md)\n
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md'"; then
  pass "Case 14s1: nested-list links remain rendered prose"
else
  fail "Case 14s1 nested-list unexpected (rc=$rc): $out"
fi

set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|Governance\n    See [the audit](hub.md)\n
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md'"; then
  pass "Case 14s1: indented paragraph continuations remain rendered prose"
else
  fail "Case 14s1 paragraph-continuation unexpected (rc=$rc): $out"
fi

set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|> Governance\n    See [the audit](hub.md)\n
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md'"; then
  pass "Case 14s1: lazy blockquote continuations remain rendered prose"
else
  fail "Case 14s1 blockquote-continuation unexpected (rc=$rc): $out"
fi

# The same indentation after a heading or blank line really does start an
# indented code block, so link-shaped examples there must stay ignored.
for code_body in \
  '# Governance\n    See [the audit](hub.md)\n' \
  'Governance\n\n    See [the audit](hub.md)\n' \
  'Governance\n===\n    See [the audit](hub.md)\n' \
  '* * *\n    See [the audit](hub.md)\n' \
  '> # Governance\n    See [the audit](hub.md)\n'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
    "docs/agents/shared.md|$code_body
docs/agents/hub.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "0" ]; then
    pass "Case 14s1: genuine indented code remains ignored"
  else
    fail "Case 14s1 indented-code control unexpected (rc=$rc): $out"
  fi
done

# A backtick fence opener whose info string itself contains a backtick is
# invalid CommonMark. The following link remains rendered prose and must not be
# hidden until an apparent closing fence.
set +e
out=$(run_with_doc_bodies "$MANIFEST_TRUTH" \
  'docs/agents/shared.md|```js `example`\n[audit](hub.md)\n```\n
docs/agents/hub.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub.md'"; then
  pass "Case 14s2: invalid backtick fence opener does not hide a rendered link"
else
  fail "Case 14s2 unexpected (rc=$rc): $out"
fi

# --- Case 14t: balanced parentheses in inline destinations ----------
# A valid bare Markdown destination may contain balanced parentheses,
# and an angle-bracket destination may contain them without escaping.
# Stopping at the first `)` truncates both spellings to `hub(1` and lets
# a canonical doc ship a consumer-broken link to a hub-only sibling.
MANIFEST_TRUTH_PAREN="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/hub(1).md
    class: hub-only
"
for paren_link in '[the audit](hub(1).md)' '[the audit](<hub(1).md>)'; do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH_PAREN" \
    "docs/agents/shared.md|See $paren_link for details.
docs/agents/hub(1).md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub(1).md' by a relative Markdown link"; then
    pass "Case 14t: balanced-parenthesis link '$paren_link' fails closed"
  else
    fail "Case 14t ('$paren_link') unexpected (rc=$rc): $out"
  fi
done

# Reference definitions apply CommonMark backslash unescaping to ASCII
# punctuation too. Keeping the escapes in the extracted target makes these
# valid links compare as `hub\(1\).md` instead of the owned `hub(1).md`.
for escaped_ref in \
  'See [the audit].\n\n[the audit]: hub\\(1\\).md' \
  'See [the audit].\n\n[the audit]:\nhub\\(1\\).md'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_TRUTH_PAREN" \
    "docs/agents/shared.md|$escaped_ref
docs/agents/hub(1).md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "1" ] && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hub(1).md' by a relative Markdown link"; then
    pass "Case 14u: backslash-escaped reference destination fails closed"
  else
    fail "Case 14u ('$escaped_ref') unexpected (rc=$rc): $out"
  fi
done

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
