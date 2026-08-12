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

# ── CommonMark conformance matrix (Cases 14v / 14w / 14x) ────────────
#
# Every row below is derived from the CommonMark 0.31.2 spec section it
# names, not from the shape of the code under test, and each is checked
# against the rendered HTML the repo's own reference parser produces
# (markdown-it-py's commonmark preset — the parser the prose-wrap
# tooling already relies on, and the one the wrapped-reference-definition
# support above was verified against).
#
# Assertions are ANCHORED and EXACT rather than substring greps: the
# whole diagnostic line is reconstructed and matched with `grep -xF`, and
# the number of `FAIL:` lines in the output is counted, so a row can
# neither pass on a fragment of some unrelated failure nor hide a second
# finding it did not intend to provoke.
CM_TAIL="— a canonical doc is mirrored verbatim to every consumer, a hub-only doc never travels, so that reference resolves on the hub and 404s downstream. Drop the reference, restate the content inline, or link it as an absolute https://github.com/... URL."

# The link RENDERS, so check 10 must report it — exactly once, naming the
# resolved-target spelling, with no other failure alongside it.
expect_rendered() {
  local label="$1" rc="$2" out="$3" hub="${4:-docs/agents/hub.md}"
  local want="FAIL: canonical doc 'docs/agents/shared.md' references the hub-only doc '$hub' by a relative Markdown link that resolves to it $CM_TAIL"
  local exact total
  exact=$(printf '%s\n' "$out" | grep -cxF -- "$want" || true)
  total=$(printf '%s\n' "$out" | grep -c '^FAIL: ' || true)
  if [ "$rc" = "1" ] && [ "$exact" = "1" ] && [ "$total" = "1" ]; then
    pass "$label"
  else
    fail "$label (rc=$rc exact=$exact total=$total): $out"
  fi
}

# The link does NOT render — it is code, raw HTML, or a destination that
# never resolves to the hub-only path — so the run must be a clean PASS
# over the whole fixture inventory, with no failure of any kind.
expect_not_rendered() {
  local label="$1" rc="$2" out="$3" ndocs="${4:-2}"
  local want="check_doc_ownership: PASS ($ndocs docs/agents doc(s) classified; classes: canonical per-repo-owned hub-only)"
  local exact total
  exact=$(printf '%s\n' "$out" | grep -cxF -- "$want" || true)
  total=$(printf '%s\n' "$out" | grep -c '^FAIL: ' || true)
  if [ "$rc" = "0" ] && [ "$exact" = "1" ] && [ "$total" = "0" ]; then
    pass "$label"
  else
    fail "$label (rc=$rc exact=$exact total=$total): $out"
  fi
}

# One canonical-doc body against the two-doc truth fixture.
run_truth_body() {
  run_with_doc_bodies "$MANIFEST_TRUTH" \
    "docs/agents/shared.md|$1
docs/agents/hub.md|# Hub-only machinery"
}

# The matrix's oracle, actually executed.
#
# Every row declares a RENDERING verdict — "a reader following this body
# reaches the hub-only doc" or "no reader does". That is a claim about the
# reference parser, so the reference parser should decide it instead of a
# hard-coded expectation that agrees with the implementation by construction.
# Left unrun, an assumption shared by check_doc_ownership and these rows
# passes the suite silently: it hid two rows asserting that eight decimal and
# seven hex digits do NOT decode, when markdown-it-py decodes both — a
# reader reached `hub.md` and neither the checker nor the suite noticed.
#
# Availability follows scripts/lint-md-prose-wrap.sh: the interpreter is
# ${MD_REFLOW_PYTHON:-python3} and markdown-it-py is pinned at 4.2.0 by
# .github/workflows/md-prose-wrap.yml, which soft-passes without it. A
# checkout lacking it keeps the declared verdicts rather than failing on a
# missing dependency.
#
# Availability is NOT enough, though: a renderer is only an oracle for the
# CommonMark version these rows are written against. The propagated
# repo_lint.yml installs nothing and picks up whatever markdown-it-py the
# runner happens to carry, which today is a 0.30-era build — and 0.30 and
# 0.31 disagree about the HTML block condition 6 tag list that Case 14w
# exercises directly. Cross-checking 0.31 rows against a 0.30 renderer
# reports the ROWS as wrong when it is the renderer that targets another
# spec, so activation is gated on a conformance probe (below) and a
# non-conforming renderer SKIPS the cross-check with that reason named.
CM_ORACLE_PYTHON="${MD_REFLOW_PYTHON:-python3}"
CM_ORACLE="$WORKDIR/cm_oracle.py"
cat > "$CM_ORACLE" <<'CM_ORACLE_EOF'
"""Print `rendered` when markdown-it-py's commonmark preset resolves any link
or image in the body (read from stdin) to the hub-only doc, else
`not_rendered`. Destinations are percent-decoded and resolved relative to the
canonical doc, which is what a reader's browser does with the emitted href."""
import posixpath
import sys
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt

DOC = "docs/agents/shared.md"
HUB = "docs/agents/hub.md"
BASE = posixpath.dirname(DOC)

destinations = []
for token in MarkdownIt("commonmark").parse(sys.stdin.read()):
    if token.type != "inline":
        continue
    for child in token.children or []:
        if child.type == "link_open":
            destinations.append(child.attrGet("href"))
        elif child.type == "image":
            destinations.append(child.attrGet("src"))

verdict = "not_rendered"
for dest in destinations:
    if not dest:
        continue
    parts = urlsplit(dest)
    if parts.scheme or parts.netloc:
        continue  # absolute URL — never a repo-relative reference
    path = unquote(parts.path)
    if path and posixpath.normpath(posixpath.join(BASE, path)) == HUB:
        verdict = "rendered"
        break
print(verdict)
CM_ORACLE_EOF

# The conformance probe. Two tags, one in each direction, both drawn from the
# 0.30 -> 0.31 delta rather than from any row that has ever failed: 0.31
# removed `source` from the condition 6 tag list and added `search`. A
# renderer that inverts either one is answering a different specification
# than the rows ask about, and its verdicts are not evidence about them.
CM_ORACLE_PROBE="$WORKDIR/cm_oracle_probe.py"
cat > "$CM_ORACLE_PROBE" <<'CM_ORACLE_PROBE_EOF'
"""Print `match` when the installed markdown-it-py implements the CommonMark
version the matrix rows are written against, on the axis the matrix is
version-sensitive about; otherwise print a one-line reason it is not an
oracle for those rows."""
from markdown_it import MarkdownIt

MD = MarkdownIt("commonmark")


def opens_html_block(tag):
    """True when `<tag>` starts an HTML block that swallows the next line.

    A condition 6 tag closes the surrounding text flow, so the four-space
    continuation below is raw block content and its link never renders. Any
    other tag leaves a paragraph open and the continuation still links.
    """
    body = "<" + tag + ">governance\n    See [the audit](hub.md)\n"
    for token in MD.parse(body):
        if token.type != "inline":
            continue
        for child in token.children or []:
            if child.type == "link_open":
                return False
    return True


EXPECTED = (("search", True), ("source", False))
seen = [(tag, opens_html_block(tag)) for tag, _ in EXPECTED]
if seen == [(tag, want) for tag, want in EXPECTED]:
    print("match")
else:
    print(
        "renderer HTML block condition 6 tag list is not CommonMark 0.31 ("
        + ", ".join(tag + "=" + str(got) for tag, got in seen)
        + ")"
    )
CM_ORACLE_PROBE_EOF

CM_ORACLE_READY=0
CM_ORACLE_SKIP_REASON=""
if ! command -v "$CM_ORACLE_PYTHON" >/dev/null 2>&1; then
  CM_ORACLE_SKIP_REASON="$CM_ORACLE_PYTHON not found"
elif ! "$CM_ORACLE_PYTHON" -c 'import markdown_it' >/dev/null 2>&1; then
  CM_ORACLE_SKIP_REASON="markdown-it-py absent"
else
  set +e
  cm_probe_out=$("$CM_ORACLE_PYTHON" "$CM_ORACLE_PROBE" 2>&1)
  cm_probe_rc=$?
  set -e
  if [ "$cm_probe_rc" != "0" ]; then
    CM_ORACLE_SKIP_REASON="reference-renderer probe errored (rc=$cm_probe_rc): $cm_probe_out"
  elif [ "$cm_probe_out" != "match" ]; then
    CM_ORACLE_SKIP_REASON="$cm_probe_out"
  else
    CM_ORACLE_READY=1
  fi
fi
if [ "$CM_ORACLE_READY" != "1" ]; then
  echo "NOTE: CommonMark matrix rows run without the reference-renderer" \
       "cross-check — $CM_ORACLE_SKIP_REASON" >&2
fi

# Drive a `label|body` matrix through run_truth_body and assert the given
# rendering verdict for every row. The reference renderer is consulted first:
# when it disagrees with the row's declared verdict the ROW is wrong, and no
# checker result can settle that, so the disagreement is reported instead.
run_cm_matrix() {
  local verdict="$1" prefix="$2" row label body want seen orc
  shift 2
  want="not_rendered"
  [ "$verdict" = "expect_rendered" ] && want="rendered"
  for row in "$@"; do
    label="${row%%|*}"
    body="${row#*|}"
    if [ "$CM_ORACLE_READY" = "1" ]; then
      set +e
      seen=$(printf '%b\n' "$body" | "$CM_ORACLE_PYTHON" "$CM_ORACLE" 2>&1)
      orc=$?
      set -e
      if [ "$orc" != "0" ]; then
        fail "$prefix: $label — reference renderer errored (rc=$orc): $seen"
        continue
      fi
      if [ "$seen" != "$want" ]; then
        fail "$prefix: $label — reference renderer says '$seen', row declares '$want'"
        continue
      fi
    fi
    set +e
    out=$(run_truth_body "$body")
    rc=$?
    set -e
    "$verdict" "$prefix: $label" "$rc" "$out"
  done
}

# --- Case 14v: character references in link destinations (#807) ------
# § Entity and numeric character references: a reference is recognized in
# a link destination and resolves to the character it names, so the
# destination a reader's browser opens is the DECODED path. Comparing the
# encoded spelling lets `[audit](hub&#46;md)` reach a hub-only sibling
# with check 10 silent.
run_cm_matrix expect_rendered "Case 14v" \
  'decimal reference (the #807 reproduction)|See [the audit](hub&#46;md) for details.' \
  'lowercase-x hex reference|See [the audit](hub&#x2E;md) for details.' \
  'uppercase-X hex reference|See [the audit](hub&#X2E;md) for details.' \
  'seven decimal digits is within the decimal form|See [the audit](hub&#0000046;md) for details.' \
  'eight decimal digits is the longest decimal form|See [the audit](hub&#00000046;md) for details.' \
  'six hex digits is within the hex form|See [the audit](hub&#x00002E;md) for details.' \
  'eight hex digits is the longest hex form|See [the audit](hub&#x0000002E;md) for details.' \
  'named reference with an ASCII expansion|See [the audit](hub&period;md) for details.' \
  'named and numeric references spell ./ together|See [the audit](&#46;&sol;hub.md) for details.' \
  'angle-bracket destination|See [the audit](<hub&#46;md>) for details.' \
  'same-line reference definition|See [the audit].\n\n[the audit]: hub&#46;md' \
  'wrapped reference definition|See [the audit].\n\n[the audit]:\nhub&#46;md' \
  'image destination|![the audit](hub&#46;md)'

#
# Each row that must NOT resolve carries a destination that WOULD resolve to
# the hub-only path under the specific mis-decode it guards against — a
# greedy read past the missing semicolon, a lifted digit cap, or a bad
# reference silently dropped instead of left standing. A fixture that cannot
# reach `hub.md` under any of those would be clean for no reason at all.
run_cm_matrix expect_not_rendered "Case 14v" \
  'a reference needs its semicolon terminator|See [the audit](hub&#46md) for details.' \
  'nine decimal digits exceed the decimal form|See [the audit](hub&#000000046;md) for details.' \
  'nine hex digits exceed the hex form|See [the audit](hub&#x00000002E;md) for details.' \
  'code point zero is not a deleted character|See [the audit](hub&#0;.md) for details.' \
  'decoded output is not rescanned for references|See [the audit](hub&#38;#46;md) for details.' \
  'a backslash escape suppresses the reference|See [the audit](hub\\&#46;md) for details.' \
  'references do not resolve inside a code span|Inline example: `[the audit](hub&#46;md)`.' \
  'a one-character body is not an entity name|See [the audit](hub&x;.md) for details.' \
  'nor is one with a character outside the name class|See [the audit](hub&per-io;.md) for details.' \
  'a numeric reference needs at least one digit|See [the audit](hub&#;.md) for details.'

# --- Case 14v2: the renderer decides WHICH code points decode --------
# § Entity and numeric character references says an invalid code point
# becomes U+FFFD, but that rule is about a reference in TEXT. In DESTINATION
# position the renderer instead leaves a reference it rejects as literal
# source, and it rejects far more than the surrogates and out-of-range
# values this checker used to: all of C0 except tab/LF/FF/CR, DEL and the
# whole C1 range, the noncharacters, and any value ending FFFE or FFFF.
#
# Decoding one of those INVENTS a destination. `h&#128;b.md` is left alone
# by the renderer, so the href still carries a `#` and a reader lands on
# `h&` — never on `h<U+0080>b.md`. A checker that decodes anyway resolves to
# exactly that name, so declaring it hub-only produced a report about a
# reference no reader can follow. The verdict on the shared `hub.md` fixture
# cannot see this, because both readings miss `hub.md`; naming the hub-only
# doc by the string the DECODE produces is what makes the two separable.
ENTITY_MANIFEST() {
  printf '%s\npaths:\n  - path: docs/agents/shared.md\n    type: canonical\n    consumers: all\ndoc_ownership:\n  - path: docs/agents/shared.md\n    class: canonical\n  - path: "%s"\n    class: hub-only\n' \
    "$MIN_HEADER" "$1"
}

C1_CHAR="$(printf '\302\200')"
set +e
out=$(run_with_doc_bodies "$(ENTITY_MANIFEST "docs/agents/h${C1_CHAR}b.md")" \
  "docs/agents/shared.md|See [the audit](h&#128;b.md) for details.
docs/agents/h${C1_CHAR}b.md|# Hub-only machinery")
rc=$?
set -e
if [ "$rc" = "0" ] && ! printf '%s\n' "$out" | grep -q 'references the hub-only doc'; then
  pass "Case 14v2: a C1 reference does not decode, so no reference to the decoded name is invented"
else
  fail "Case 14v2 (C1 stays literal) unexpected (rc=$rc): $out"
fi

# The discriminating control, one code point higher. U+00A0 IS valid, so the
# renderer decodes it and a reader really does land on a doc named with the
# character itself. Rejecting this one would be the same error in the
# opposite direction — a real reference lost — and the pair pins the
# boundary at exactly U+009F/U+00A0 rather than somewhere nearby.
NBSP="$(printf '\302\240')"
set +e
out=$(run_with_doc_bodies "$(ENTITY_MANIFEST "docs/agents/h${NBSP}b.md")" \
  "docs/agents/shared.md|See [the audit](h&#160;b.md) for details.
docs/agents/h${NBSP}b.md|# Hub-only machinery")
rc=$?
set -e
if [ "$rc" = "1" ] && printf '%s\n' "$out" | grep -qF "references the hub-only doc 'docs/agents/h${NBSP}b.md'"; then
  pass "Case 14v2: U+00A0 is one past the C1 range, so it still decodes"
else
  fail "Case 14v2 (U+00A0 decodes) unexpected (rc=$rc): $out"
fi

# --- Case 14v3: one character, three spellings, one verdict ----------
# A hub-only doc named with a non-ASCII character is reachable three ways:
# the character itself, a numeric reference, and a percent-escape. All three
# are the same destination to a reader, so all three must report.
#
# The percent spelling is where the awk implementations used to split.
# Percent-escapes name BYTES and utf8_of emits whatever unit the running awk
# counts, so emitting each escaped byte with sprintf("%c") was right on a
# byte-oriented awk and double-encoded on gawk, which reads the same call as
# a CODE POINT. That made the verdict depend on which awk ran the check —
# `%C3%B8` matched `ø.md` under BWK awk and mawk and missed it under gawk.
# This row is only meaningful when the suite runs under all three.
OSLASH="$(printf '\303\270')"
for spelling in "h${OSLASH}b.md" 'h&#248;b.md' 'h%C3%B8b.md'; do
  set +e
  out=$(run_with_doc_bodies "$(ENTITY_MANIFEST "docs/agents/h${OSLASH}b.md")" \
    "docs/agents/shared.md|See [the audit](${spelling}) for details.
docs/agents/h${OSLASH}b.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "1" ] && printf '%s\n' "$out" | grep -qF "references the hub-only doc 'docs/agents/h${OSLASH}b.md'"; then
    pass "Case 14v3: '$spelling' resolves to the same hub-only doc"
  else
    fail "Case 14v3 ('$spelling') unexpected (rc=$rc): $out"
  fi
done

# The discriminating control: the double-encoded spelling is a DIFFERENT
# name, and must not match. Without it, a decoder that emitted the
# double-encoded form for every awk would still pass the rows above by
# matching itself.
DOUBLED="$(printf '\303\203\302\270')"
set +e
out=$(run_with_doc_bodies "$(ENTITY_MANIFEST "docs/agents/h${DOUBLED}b.md")" \
  "docs/agents/shared.md|See [the audit](h%C3%B8b.md) for details.
docs/agents/h${DOUBLED}b.md|# Hub-only machinery")
rc=$?
set -e
if [ "$rc" = "0" ] && ! printf '%s\n' "$out" | grep -q 'references the hub-only doc'; then
  pass "Case 14v3: the double-encoded name is not what a percent-escape resolves to"
else
  fail "Case 14v3 (double-encoded control) unexpected (rc=$rc): $out"
fi

# --- Case 14w: HTML blocks vs inline HTML (#811) ---------------------
# § HTML blocks defines seven start conditions. Only those close the
# surrounding text flow; a line that merely BEGINS with a `<` — inline
# HTML, an autolink, an incomplete tag — is ordinary paragraph content,
# and its indented continuation lines still render links. Each row pairs
# an opener with a four-space continuation carrying the link, so the
# verdict reads directly as "was the continuation still scanned?".
run_cm_matrix expect_rendered "Case 14w" \
  'inline HTML followed by text is paragraph content|<b>bold</b> governance\n    See [the audit](hub.md)' \
  'an autolink line is a paragraph, not an HTML block|<https://example.com>\n    See [the audit](hub.md)' \
  'condition 4 needs a letter after the bang|<!5 not a declaration\n    See [the audit](hub.md)' \
  'condition 4 is uppercase-only in the parsers that render these docs|<!doctype html>\n    See [the audit](hub.md)' \
  'condition 7 cannot interrupt an open paragraph|Governance\n<custom-tag>\n    See [the audit](hub.md)' \
  'a complete tag followed by text is not condition 7|<custom-tag> governance\n    See [the audit](hub.md)' \
  'an incomplete tag is not condition 7|<custom-tag\n    See [the audit](hub.md)' \
  'a non-block tag name is not condition 6|<span>governance\n    See [the audit](hub.md)' \
  'source left the condition 6 tag list in 0.31|<source>governance\n    See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 14w" \
  'condition 1 — pre|<pre>\n    See [the audit](hub.md)' \
  'condition 1 — textarea|<textarea>\n    See [the audit](hub.md)' \
  'condition 2 — comment|<!-- note -->\n    See [the audit](hub.md)' \
  'condition 3 — processing instruction|<?php echo; ?>\n    See [the audit](hub.md)' \
  'condition 4 — declaration|<!DOCTYPE html>\n    See [the audit](hub.md)' \
  'condition 5 — CDATA section|<![CDATA[x]]>\n    See [the audit](hub.md)' \
  'condition 6 — block tag|<div>\n    See [the audit](hub.md)' \
  'condition 6 — closing block tag|</div>\n    See [the audit](hub.md)' \
  'condition 6 — tag name at end of line|<div\n    See [the audit](hub.md)' \
  'condition 6 — block tag followed by text|<div>governance\n    See [the audit](hub.md)' \
  'condition 6 — search joined the tag list in 0.31|<search>governance\n    See [the audit](hub.md)' \
  'condition 7 — complete tag alone on the line|<custom-tag>\n    See [the audit](hub.md)' \
  'condition 7 — closing tag alone on the line|</custom-tag>\n    See [the audit](hub.md)'

# --- Case 14x: list-item content classification (#812) ---------------
# § List items: an item is a container whose content is parsed as blocks
# in its own right, and indentation inside it is measured from the item
# CONTENT column. So a marker does not by itself open a paragraph — its
# first child decides — and the column at which indentation starts a code
# block moves with the marker.
run_cm_matrix expect_rendered "Case 14x" \
  'an ordinary item keeps a deep continuation visible|- Governance\n      See [the audit](hub.md)' \
  'a heading-first item still renders prose at the content column|- # Governance\n    See [the audit](hub.md)' \
  'a second paragraph inside an item renders|- Governance\n\n    See [the audit](hub.md)' \
  'an ordered marker widens the content column|1. # Governance\n      See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 14x" \
  'a heading-first item leaves genuine indented code (the #812 reproduction)|- # Governance\n      See [the audit](hub.md)' \
  'a thematic-break-first item does the same|- * * *\n      See [the audit](hub.md)' \
  'the ordered content column shifts the code threshold|1. # Governance\n       See [the audit](hub.md)' \
  'the content column resets when the list ends|- # Governance\n\nGovernance\n\n    See [the audit](hub.md)'

# --- Case 14y: the width of the run after a list marker --------------
# § List items bounds the basic case at a marker of width W followed by
# `1 <= N <= 4` spaces of indentation, which puts the content at W+N. A
# WIDER run is a different rule — "item starting with indented code" —
# under which the content column is W+1 and the first child of the item
# is an indented code block. § Tabs then says a tab in that run behaves
# as spaces to a four-column tab stop, so N is a COLUMN count and a tab
# is worth up to four of it, never one.
#
# Reading the run as an unbounded character count therefore mis-measures
# the item by N-1 columns in BOTH directions: it hides a link that really
# renders (every row below the first) and reports one that only ever
# rendered as code (the N1/N4 rows). Case 14x cannot see either, because
# none of its rows puts more than a single space after the marker.
#
# Every row is checked against markdown-it-py's commonmark preset, the
# same reference parser Cases 14v/14w/14x use.
run_cm_matrix expect_rendered "Case 14y" \
  'four spaces is still the basic case (N=4 boundary control)|-    # Governance\n       See [the audit](hub.md)' \
  'five spaces falls back to the W+1 content column|-     # Governance\n    See [the audit](hub.md)' \
  'a tab after the marker spans columns, not one character|-\t# Governance\n      See [the audit](hub.md)' \
  'a tab stop is absolute, so a wider marker consumes less of it|1.\t# Governance\n       See [the audit](hub.md)' \
  'the fallback column does not grow with the run|-      # Governance\n     See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 14y" \
  'a wide run makes the marker line itself indented code|-     See [the audit](hub.md)' \
  'four spaces keeps the code threshold at W+N+4 (N=4 control)|-    # Governance\n         See [the audit](hub.md)' \
  'a tab-set content column still starts code four past it|-\t# Governance\n        See [the audit](hub.md)' \
  'two tabs overrun the bound and code-start the item|-\t\tSee [the audit](hub.md)' \
  'a space then a tab reaches column four outside a list|Governance\n\n \t[the audit](hub.md)' \
  'the W+1 fallback still starts code four columns past itself|-     # Governance\n      See [the audit](hub.md)'

# --- Case 14z: a marker line that carries no first child -------------
# § List items: an item may "start with a blank line" — the marker and
# its whitespace run reach the end of the line and the item's first child
# begins on a LATER line. The content column is W+1, exactly as in the
# wide-run case, but nothing on the marker line remains to classify.
#
# Case 14y measures that column; it cannot see this row, because every
# one of its markers is followed by content on the same line. Reading the
# case as "consume the marker, then classify the remainder" left the
# remainder equal to the WHOLE line, so the classifier recursed on an
# unchanged string and never returned: `+ ` in a canonical doc hung the
# check or overflowed the awk stack instead of producing a verdict. The
# `-` and `*` bullets reach a setext-underline test first and so never
# showed it; `+`, `1.` and `1)` do not.
#
# The rendering rows below are the terminating half — the item's later
# content still measures from W+1 — so a regression to the old reading is
# caught as a failure rather than only as a hang. Every row is checked
# against markdown-it-py's commonmark preset, as in Cases 14v–14y.
run_cm_matrix expect_rendered "Case 14z" \
  'a `+ ` item with no first child on the marker line|+ \n    See [the audit](hub.md)' \
  'a `* ` item with no first child on the marker line|* \n    See [the audit](hub.md)' \
  'an ordered `1. ` item measures W+1 from its wider marker|1. \n     See [the audit](hub.md)' \
  'the paren-delimited `1) ` ordered marker behaves the same|1) \n     See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 14z" \
  'code still begins four columns past the W+1 content column|+ \n      See [the audit](hub.md)' \
  'the wider ordered marker moves that threshold with it|1. \n       See [the audit](hub.md)'

# --- Case 15: container transitions and list interruption ------------
# § Lists: "In order for a list to interrupt a paragraph, it must begin
# with a non-blank list item, and if ordered, the start number must be
# 1." § List items makes each item a container, so the indented-code
# threshold is a STACK of content columns — leaving an inner item
# restores the enclosing one rather than dropping to column zero.
#
# All three readings below moved a line across the code boundary, and in
# both directions: a marker that cannot interrupt a paragraph closed it
# and blanked the continuation (rendered link hidden); a dedent out of a
# nested item dropped the outer column and blanked the prose of the outer
# item (rendered link hidden); and a stale column left behind by a
# dedented line that closes an item kept real top-level code visible
# (link reported that never rendered).
#
# The controls matter as much as the reproductions: a `1.` marker and a
# bullet marker DO interrupt a paragraph, so their continuations must
# stay classified as item content, not as more of the paragraph.
#
# Every row is checked against markdown-it-py's commonmark preset first,
# as in Cases 14v-14z.
run_cm_matrix expect_rendered "Case 15" \
  'an ordered marker starting above 1 cannot interrupt a paragraph|Governance\n2. # Notes\n       See [the audit](hub.md)' \
  'an empty item cannot interrupt a paragraph either|Governance\n+ \n    See [the audit](hub.md)' \
  'leaving a nested item restores the content column of the outer one|- # outer\n  - # inner\n  Outer\n\n    See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15" \
  'a start-1 ordered marker DOES interrupt (control)|Governance\n1. # Notes\n       See [the audit](hub.md)' \
  'a bullet marker DOES interrupt (control)|Governance\n- # Notes\n      See [the audit](hub.md)' \
  'a dedent that closes the item drops its column with it|- Governance\n# Heading\n    See [the audit](hub.md)' \
  'a complete closing tag starts a type 7 HTML block|</pre>\n    See [the audit](hub.md)' \
  'the type 7 exclusion never applied to closing tags (control)|</div>\n    See [the audit](hub.md)' \
  'an opening pre tag is still condition 1 (control)|<pre>\n    See [the audit](hub.md)'

# --- Case 15b: a named reference whose expansion is TWO ASCII chars ---
# The HTML5 named-reference table has exactly 46 members whose expansion
# is entirely ASCII, and exactly one of those — `&fjlig;`, which expands
# to `fj` — is longer than a single character. Keying the decode table by
# CODE POINT could not represent it, so the destination stayed encoded
# and the hub-only sibling it reaches was never compared. This needs its
# own inventory because the resolved target is `hubfj.md`, not the
# `hub.md` every other rendering row resolves to.
MANIFEST_FJ="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/hubfj.md
    class: hub-only
"
set +e
out=$(run_with_doc_bodies "$MANIFEST_FJ" \
  'docs/agents/shared.md|See [the audit](hub&fjlig;.md) for details.
docs/agents/hubfj.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] \
   && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hubfj.md'"; then
  pass "Case 15b: a two-character ASCII named reference resolves to its target"
else
  fail "Case 15b unexpected (rc=$rc): $out"
fi

# CONTROL: the same destination spelled literally must report identically,
# so the row above passes because the reference DECODED and not because
# something else in the fixture failed.
set +e
out=$(run_with_doc_bodies "$MANIFEST_FJ" \
  'docs/agents/shared.md|See [the audit](hubfj.md) for details.
docs/agents/hubfj.md|# Hub-only machinery')
rc=$?
set -e
if [ "$rc" = "1" ] \
   && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hubfj.md'"; then
  pass "Case 15b: the literal spelling of that target reports identically (control)"
else
  fail "Case 15b control unexpected (rc=$rc): $out"
fi

# --- Case 15c: every marker on a line records its own container ------
# § List items makes each marker a container in its own right, so
# `- - # inner` opens TWO items — content columns 2 and 4 — and the line
# that dedents back to column 2 closes only the inner one. Recording just
# the SUMMED column left the outer item with no frame at all: that dedent
# popped the single column-4 frame, dropped the code threshold to zero,
# and blanked the second paragraph of the outer item as top-level
# indented code, taking its link out of the scan with it.
#
# Case 15 covers the one-marker-per-line dedent and cannot see this row,
# because with a single marker the sum and the innermost frame are the
# same number. The control below is exactly that shape, and it renders at
# the same boundary — which is why the summed column looked correct.
#
# The boundary is the point: with the outer frame restored, code begins
# four columns past the OUTER content column (2 + 4 = 6), so five spaces
# render and six do not. Every row is checked against markdown-it-py's
# commonmark preset, as in Cases 14v-15b.
run_cm_matrix expect_rendered "Case 15c" \
  'two markers on one line keep the OUTER frame as well as the inner|- - # inner\n  Outer\n\n     See [the audit](hub.md)' \
  'one marker on the line is the shape the summed column got right|- # inner\n  Outer\n\n     See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15c" \
  'code begins four columns past the OUTER content column, not the inner|- - # inner\n  Outer\n\n      See [the audit](hub.md)' \
  'the one-marker control shares that boundary exactly|- # inner\n  Outer\n\n      See [the audit](hub.md)'

# --- Case 15d: paragraph interruption reads the START NUMBER ---------
# § Lists restricts interruption to an ordered item whose "start number
# is 1" — a property of the number the digits SPELL, not of how they are
# spelled. `01.` and `1.` both start at 1 and both interrupt a paragraph.
# Matching the literal spellings `1.` / `1)` instead rejected every
# leading-zero form: the paragraph was kept open, no item container was
# ever recorded, and the content of the item was then measured against
# column zero and blanked as top-level code.
#
# Case 15 covers the start-number restriction only through `2.`, which
# the spelling test and the parsed test agree about; the disagreement is
# visible only where the two readings differ, which is a leading zero.
#
# `01. ` puts content at column 4, so item prose runs to seven spaces and
# code begins at eight. The non-interrupting control is a genuinely
# different document — one paragraph, then top-level code from column
# four — which is why its boundary is four rather than eight.
run_cm_matrix expect_rendered "Case 15d" \
  'a leading-zero ordered marker starts at 1, so it interrupts|Governance\n01. # Notes\n\n       See [the audit](hub.md)' \
  'the plain spelling of the same start number (control)|Governance\n1. # Notes\n\n      See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15d" \
  'code still begins four columns past the item content column|Governance\n01. # Notes\n\n        See [the audit](hub.md)' \
  'a leading zero does not rescue a start number above 1|Governance\n02. # Notes\n\n    See [the audit](hub.md)'

# --- Case 15e: an ordered marker is bounded at nine digits -----------
# § List items: an ordered-list marker is "1-9 arabic digits" followed by
# `.` or `)`. A tenth digit makes it ordinary paragraph text, so the line
# that follows is a lazy paragraph continuation and its link renders —
# but an unbounded pattern reads it as a marker with content column 12
# and suppresses that continuation as indented code.
#
# The two rows are a minimal pair: the SAME sixteen-space continuation,
# one digit of difference in the marker, opposite verdicts. Nine digits
# really is a marker, so its item does start indented code at eleven plus
# four — which is what makes the bound observable rather than cosmetic.
run_cm_matrix expect_rendered "Case 15e" \
  'ten digits is not a marker, so the next line continues the paragraph|1234567890. # Notes\n                See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15e" \
  'nine digits IS a marker and its item code-starts at W+1+4 (control)|123456789. # Notes\n                See [the audit](hub.md)'

# --- Case 15f: character references above ASCII (#807) ---------------
# § Entity and numeric character references resolves a reference inside a
# link destination, so `[audit](hub&#248;.md)` opens `hubø.md`. Capping
# the decode at ASCII compared every non-ASCII reference by its ENCODED
# spelling, which is a silent false negative: the reader reaches the
# hub-only sibling and the scan never sees it.
#
# The cap existed for a real portability reason, and these rows are the
# regression test for the fix as much as the conformance test for the
# rule — run the suite under BWK awk, gawk and mawk. Measured on BWK awk
# 20200816, gawk 5.4.1 and mawk 1.3.4 in a UTF-8 locale: `sprintf("%c",
# 252)` emits the single Latin-1 byte `fc` on BWK awk and mawk but the
# UTF-8 character `c3 bc` on gawk, while a hand-built byte pair `195`
# `188` is right on BWK awk and mawk and double-encoded to `c3 83 c2 bc`
# on gawk. Neither primitive is portable alone; the decoder picks the one
# that is correct for the implementation it is running on.
#
# U+00F8 is deliberate. It has no canonical decomposition, so its NFC and
# NFD spellings are byte-identical and this fixture behaves the same on a
# normalizing filesystem as on a preserving one — a decomposable letter
# such as U+00FC would make the row depend on the runner.
MANIFEST_NONASCII="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/hubø.md
    class: hub-only
"
for ref_spelling in \
  'hub&#248;.md' 'hub&#xF8;.md' 'hub&#XF8;.md' 'hub&#0000248;.md' \
  'hub&oslash;.md' 'hubø.md'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_NONASCII" \
    "docs/agents/shared.md|See [the audit]($ref_spelling) for details.
docs/agents/hubø.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "1" ] \
     && echo "$out" | grep -q "references the hub-only doc 'docs/agents/hubø.md'"; then
    pass "Case 15f: '$ref_spelling' resolves to its non-ASCII target"
  else
    fail "Case 15f ('$ref_spelling') unexpected (rc=$rc): $out"
  fi
done

# A decoded newline must not split ONE destination into two records.
# `prefix&NewLine;hub.md` is a single destination that reaches no file;
# emitting the decoded newline raw made the tail its own record, and that
# record `hub.md` then false-matched the hub-only sibling and reported a
# reference no reader can follow. The reference parser keeps it as one
# percent-encoded destination, `prefix%0Ahub.md`.
run_cm_matrix expect_not_rendered "Case 15f" \
  'a decoded newline does not split one destination into two targets|See [the audit](prefix&NewLine;hub.md) for details.' \
  'the numeric spelling of the same character behaves identically|See [the audit](prefix&#10;hub.md) for details.' \
  'a carriage return is held to the same rule|See [the audit](prefix&#13;hub.md) for details.'

# --- Case 15g: indentation decides whether a block can interrupt -----
# § Indented code blocks: indented code "cannot interrupt a paragraph".
# So while a paragraph is open, a line four or more columns past the
# current container is lazy continuation TEXT no matter what block it
# looks like — the marker, hash or tag is ordinary paragraph content at
# that depth. The classifier is handed the line with its indentation
# stripped, so it could not see the column, read the shape as a block
# start, closed the paragraph and blanked the continuation after it.
#
# Case 15 tests interruption by SHAPE (a non-1 ordered marker, an empty
# item) and cannot see this: here the shape is a perfectly valid
# interrupting marker and only its COLUMN stops it.
#
# The last two rows are the discriminating controls, and they matter
# because most rows in this family render either way. Same nine-space
# link line, marker moved one column: at three columns the bullet DOES
# interrupt, so the item content column is 5 and nine spaces is item
# code; at four it does not interrupt, so nine spaces is more paragraph.
# And with no paragraph open at all, the same four-column shape is
# ordinary top-level indented code.
#
# Every row is checked against markdown-it-py's commonmark preset.
run_cm_matrix expect_rendered "Case 15g" \
  'a bullet four columns in cannot interrupt an open paragraph|Governance\n    - # Heading\n    [the audit](hub.md)' \
  'nor can an ordered marker at that column|Governance\n    1. # Heading\n    [the audit](hub.md)' \
  'nor an ATX heading|Governance\n    # Heading\n    [the audit](hub.md)' \
  'nor a thematic break|Governance\n    ---\n    [the audit](hub.md)' \
  'nor a block quote|Governance\n    > quoted\n    [the audit](hub.md)' \
  'an HTML block is continuation text at four columns too|Governance\n    <div>\n    [the audit](hub.md)' \
  'the continuation keeps running past the code threshold|Governance\n    - # Heading\n         [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15g" \
  'one column less and the bullet interrupts, making that line item code|Governance\n   - # Heading\n         [the audit](hub.md)' \
  'with no paragraph open the same shape is top-level indented code|    - # Heading\n    [the audit](hub.md)'

# --- Case 15h: percent escapes must be WELL-FORMED UTF-8 -------------
# A continuation-byte range check is not UTF-8 well-formedness. Unicode
# Table 3-7 also bounds the scalar each sequence LENGTH may carry, and a
# decoder that checks only the range accepts an overlong spelling, a
# surrogate and a scalar past U+10FFFF — inventing a character the reader
# never sees. `%E0%81%A8` is the overlong three-byte spelling of `h`: the
# renderer yields replacement characters and reaches nothing, while a
# range-only decoder read `hub.md` and reported a canonical doc for a link
# nobody can follow.
#
# The last two rows are the discriminating controls. Rejecting malformed
# input is trivially satisfied by rejecting everything, so a well-formed
# escape for the same letter — written in the position the overlong rows
# attack — must still decode and still be reported.
#
# The overlong pair is what fails if the bounds come back out; a surrogate
# and an above-ceiling scalar cannot be made to spell an ASCII target, so
# those two rows assert the same property at the other two boundaries
# without being able to name `hub.md`. They are kept because the property
# is "no malformed escape resolves to the target", not "these two inputs
# do not".
run_cm_matrix expect_not_rendered "Case 15h" \
  'an overlong three-byte escape does not spell the target|See [the audit](%E0%81%A8ub.md) for details.' \
  'an overlong four-byte escape does not either|See [the audit](%F0%80%81%A8ub.md) for details.' \
  'a surrogate escape is not a character|See [the audit](%ED%A0%A8ub.md) for details.' \
  'an escape above U+10FFFF is not a character|See [the audit](%F4%90%80%A8ub.md) for details.'

run_cm_matrix expect_rendered "Case 15h" \
  'the well-formed escape for that same letter still decodes|See [the audit](%68ub.md) for details.' \
  'and so does one in the middle of the name|See [the audit](h%75b.md) for details.'

# --- Case 15i: a dedented fence closes the containers it leaves ------
# § Fenced code blocks: a fence opener is a block start like any other, so
# the container stack is updated at its indentation before it is handled.
# While the pop ran only on the lines that reach the code-threshold test,
# the fence branch returned first and left the previous list frame
# standing: after `- # Item` a column-zero fence closed the item for the
# renderer but not for the checker, whose stale two-column frame raised
# the code threshold to six and left a four-space line scan-visible that
# the renderer had already made top-level indented code.
#
# The controls separate the fix from a blanket "a fence clears the stack":
# a fence INSIDE the item must LEAVE the frame standing, so the same
# four-space line after it is still item prose, and six columns past it is
# still code.
run_cm_matrix expect_not_rendered "Case 15i" \
  'a dedented fence closes the item, so the line after it is top-level code|- # Item\n\n```\ncode\n```\n\n    See [the audit](hub.md)' \
  'a tilde fence closes it the same way|- # Item\n\n~~~\ncode\n~~~\n\n    See [the audit](hub.md)' \
  'six columns past a surviving item frame is still code|- # Item\n\n  ```\n  code\n  ```\n\n      See [the audit](hub.md)'

run_cm_matrix expect_rendered "Case 15i" \
  'without the fence that four-space line is item prose|- # Item\n\n    See [the audit](hub.md)' \
  'a fence INSIDE the item leaves the item frame standing|- # Item\n\n  ```\n  code\n  ```\n\n    See [the audit](hub.md)'

# --- Case 15j: an item opens a FRESH block context -------------------
# § List items: the content of an item is parsed as blocks in its own
# right, so no paragraph is open inside it — whatever was open outside
# stopped at the marker. While the classifier recursed into the item
# carrying the OUTER paragraph state, the item re-applied the
# paragraph-interruption rules to its own first child: under an open
# paragraph the nested marker of `- 2. # Heading` was rejected as unable
# to interrupt, so that item never pushed a content column, and prose six
# or seven columns in was measured against the OUTER frame and blanked as
# code.
#
# This one runs the other way from the rest of the family. The renderer
# shows that line as ordinary nested-item prose, so the checker was not
# raising a false alarm — it was MISSING a hub-only reference, which is
# the direction that lets a bad link ship.
#
# The controls are chosen so that "always recurse with a fresh paragraph"
# cannot pass by being indiscriminate: the item content column must still
# bound indented code (nine columns in IS code), a nested marker starting
# at 1 — which could always interrupt — must be unchanged, and the shape
# with no outer paragraph at all must stay exactly as it was.
run_cm_matrix expect_rendered "Case 15j" \
  'a nested marker that cannot interrupt the outer paragraph still opens its own item|Governance\n- 2. # Heading\n\n       See [the audit](hub.md)' \
  'six columns in is nested-item prose too|Governance\n- 2. # Heading\n\n      See [the audit](hub.md)' \
  'a nested marker starting at 1 behaves identically|Governance\n- 1. # Heading\n\n       See [the audit](hub.md)' \
  'with no outer paragraph open the same shape already worked|- 2. # Heading\n\n       See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15j" \
  'nine columns past the nested content column is genuine item code|Governance\n- 2. # Heading\n\n         See [the audit](hub.md)'

# --- Case 15k: a sibling item REPLACES the one before it -------------
# § List items: a marker at column S closes every container whose content
# starts deeper than S — including the sibling item it replaces. The
# frame push popped against the new CONTENT column instead of the marker
# column, which is the same value only while consecutive markers keep the
# same width. Widen the run after the second marker and the first frame
# is shallower than the second, so it survived UNDERNEATH it: `- one`
# then `-   # two` left a column-2 frame below a column-4 frame, and once
# the list closed that stale frame raised the code threshold to six and
# scanned a four-space line the renderer had already made top-level
# indented code.
#
# The rows widen the run three ways — two spaces, three spaces, and an
# ordered marker — because the defect is about the RELATION between the
# marker column and the content column, not about any one width. The
# controls are the equal-width case, where the two columns coincide and
# the old code was already right, and the same widened shape with the
# link one column shallower, which is genuinely still item prose.
run_cm_matrix expect_not_rendered "Case 15k" \
  'a widened sibling must not leave the previous frame underneath it|- one\n-   # two\n  # outside\n    [audit](hub.md)' \
  'a three-space run does the same|- one\n-    # two\n  # outside\n    [audit](hub.md)' \
  'ordered siblings widen the same way|1. one\n1.   # two\n   # outside\n    [audit](hub.md)'

run_cm_matrix expect_rendered "Case 15k" \
  'equal-width siblings were always right|- one\n- # two\n  # outside\n    [audit](hub.md)' \
  'one column shallower is still item prose|- one\n-   # two\n  # outside\n   [audit](hub.md)'

# --- Case 15l: the newline sentinel must not alias a real name -------
# Targets are emitted one per line, so a decoded CR or LF would split one
# destination into two records. Substituting a character cannot fix that
# whichever character is chosen: U+FFFD was picked on the claim that it
# "matches no declared path", and U+FFFD is a perfectly legal pathname
# character — so `prefix&NewLine;hub.md` matched a hub-only doc named
# `prefix<U+FFFD>hub.md` and invented an ownership failure.
#
# The destination is dropped instead, which cannot alias anything because
# no value is compared. Every spelling that reaches a newline is checked,
# in both bases and through both the reference and the percent-escape
# paths, because they resolve by different code paths — a named
# expansion is built once at startup and returned verbatim, so it does
# not pass back through the decoder that raises the flag.
#
# The last row is the discriminating control: dropping every destination
# would satisfy all the rows above, so the LITERAL U+FFFD spelling must
# still resolve to the same doc and still be reported.
MANIFEST_FFFD="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: docs/agents/prefix�hub.md
    class: hub-only
"
# `%00` is the same rule on a different byte. NUL is not a newline, but it
# is likewise not a byte any pathname can carry, so substituting for it can
# only alias — and `%00` reached the same U+FFFD-named doc. Every OTHER
# control byte IS legal in a pathname and is emitted as itself, which is why
# `%01` needs no row here and gets none.
#
# A MALFORMED UTF-8 escape run aliases by exactly the same mechanism, and
# the last four spellings are the four ways a run can be malformed: a byte
# that is no part of any sequence, a stray continuation, a truncated run,
# and an overlong spelling. Each one decoded to U+FFFD and compared, so
# `prefix%FFhub.md` matched the U+FFFD-named doc although the href a reader
# follows still says `%FF`, whose byte is not that name in UTF-8 or in any
# other encoding a repository path uses.
for nl_spelling in \
  'prefix&NewLine;hub.md' 'prefix&#10;hub.md' 'prefix&#13;hub.md' \
  'prefix&#x0A;hub.md' 'prefix%0Ahub.md' 'prefix%0Dhub.md' \
  'prefix%00hub.md' 'prefix%FFhub.md' 'prefix%80hub.md' \
  'prefix%C3hub.md' 'prefix%E0%80%80hub.md'
do
  set +e
  out=$(run_with_doc_bodies "$MANIFEST_FFFD" \
    "docs/agents/shared.md|See [the audit]($nl_spelling) for details.
docs/agents/prefix�hub.md|# Hub-only machinery")
  rc=$?
  set -e
  if [ "$rc" = "0" ] && echo "$out" | grep -q "check_doc_ownership: PASS"; then
    pass "Case 15l: '$nl_spelling' does not alias the U+FFFD-named doc"
  else
    fail "Case 15l ('$nl_spelling') unexpected (rc=$rc): $out"
  fi
done

set +e
out=$(run_with_doc_bodies "$MANIFEST_FFFD" \
  "docs/agents/shared.md|See [the audit](prefix�hub.md) for details.
docs/agents/prefix�hub.md|# Hub-only machinery")
rc=$?
set -e
if [ "$rc" = "1" ] \
   && echo "$out" | grep -q "references the hub-only doc 'docs/agents/prefix�hub.md'"; then
  pass "Case 15l: the literal U+FFFD spelling still resolves (control)"
else
  fail "Case 15l (literal U+FFFD control) unexpected (rc=$rc): $out"
fi

# --- Case 15m: a list inside a block quote dies with the quote -------
# § Block quotes: an unmarked blank line ends the quote, and everything
# open inside it ends too. A container frame recorded only its COLUMN,
# which cannot express that: after `> - # Heading` the list frame sat at
# column 4 and outlived the quote, so a following four-space line was
# measured against a list that no longer existed and top-level indented
# code was scanned as prose. Frames now carry the quote depth they were
# opened at and pop when the line is shallower.
#
# The controls are both directions of "does the quote still hold": the
# same list still inside the quote must keep its frame, and the same
# shape with no quote at all must be unchanged.
run_cm_matrix expect_not_rendered "Case 15m" \
  'an unmarked blank line ends the quote and the list inside it|> - # Heading\n\n    See [the audit](hub.md)'

run_cm_matrix expect_rendered "Case 15m" \
  'the frame survives while the quote does|> - # Heading\n>\n>     See [the audit](hub.md)' \
  'the same shape outside a quote is unchanged|- # Heading\n\n    See [the audit](hub.md)'

# --- Case 15n: an ENCODED delimiter is path data ---------------------
# Query and fragment delimiters are recognized in URL syntax, before
# percent decoding — that is why the extractor strips `[?#]...` first and
# decodes afterwards. It follows that a pure fragment can never reach the
# consumer as text: `#section` arrives empty and `a.md#frag` arrives as
# `a.md`. The consumer re-tested for a leading `#` anyway, and that
# redundant test was actively wrong, because a decoded `%23` is a
# pathname character by then. A hub-only doc named `#hub.md` was
# therefore reachable through `%23hub.md` with check 10 silent.
#
# `%3F` is the same rule on the other delimiter, and it already worked —
# it is here so the pair cannot drift apart. The real fragment is the
# control that keeps the strip honest.
MANIFEST_HASH="$MIN_HEADER
paths:
  - path: docs/agents/shared.md
    type: canonical
    consumers: all
doc_ownership:
  - path: docs/agents/shared.md
    class: canonical
  - path: \"docs/agents/#hub.md\"
    class: hub-only
  - path: \"docs/agents/?hub.md\"
    class: hub-only
"
set +e
out=$(run_with_doc_bodies "$MANIFEST_HASH" \
  "docs/agents/shared.md|See [the audit](%23hub.md) for details.
docs/agents/#hub.md|# Hub-only machinery
docs/agents/?hub.md|# Hub-only machinery")
rc=$?
set -e
if [ "$rc" = "1" ] \
   && echo "$out" | grep -q "references the hub-only doc 'docs/agents/#hub.md'"; then
  pass "Case 15n: an encoded '#' is a pathname character, not a fragment"
else
  fail "Case 15n (%23 path) unexpected (rc=$rc): $out"
fi

set +e
out=$(run_with_doc_bodies "$MANIFEST_HASH" \
  "docs/agents/shared.md|See [the audit](%3Fhub.md) for details.
docs/agents/#hub.md|# Hub-only machinery
docs/agents/?hub.md|# Hub-only machinery")
rc=$?
set -e
if [ "$rc" = "1" ] \
   && echo "$out" | grep -q "references the hub-only doc 'docs/agents/?hub.md'"; then
  pass "Case 15n: an encoded '?' is a pathname character, not a query"
else
  fail "Case 15n (%3F path) unexpected (rc=$rc): $out"
fi

set +e
out=$(run_truth_body 'See [the audit](other.md?hub.md) for details.')
rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_doc_ownership: PASS"; then
  pass "Case 15n: a real query string is still discarded (control)"
else
  fail "Case 15n (real query control) unexpected (rc=$rc): $out"
fi

set +e
out=$(run_truth_body 'See [the audit](other.md#hub.md) for details.')
rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_doc_ownership: PASS"; then
  pass "Case 15n: a real fragment is still discarded (control)"
else
  fail "Case 15n (real fragment control) unexpected (rc=$rc): $out"
fi

# --- Case 15o: a marker line with no content is still a container ----
# § List items: "When the list item starts with a blank line, the number
# of spaces following the list marker does not change the required
# indentation" — the content column is W+1. Two tests upstream of that
# rule stopped such a line from ever reaching it.
#
# The setext-underline shape test ran with nothing open, and a setext
# underline only exists UNDER a paragraph. `-` and `- ` are spelled with
# the underline character, so a blank-first bullet was classified as a
# block boundary, pushed no frame, and left the threshold at four: a
# hub-only link four or five columns beneath it was blanked as top-level
# code and MISSED — the false-negative direction. `=` alone is the same
# defect without a list in sight: it opens a paragraph for both
# renderers, so the line below it is a lazy continuation whose link
# renders.
#
# The marker test then required a whitespace run after the marker, so a
# BARE marker was not a marker at all. For `*`, `+` and the ordered forms
# that runs the other way, as a false positive: with no frame, six
# columns under `*` was scanned as a lazy continuation of a phantom
# paragraph although the renderer had already made it item code.
#
# The one-blank bound comes with the fix rather than after it. An item
# that begins with a blank line may hold exactly that one, so the frame
# these rows create must close on the next blank — otherwise fixing the
# miss above would invent a false ownership failure four columns under an
# item that no longer exists.
#
# Every row was measured against BOTH renderers — markdown-it-py 4.2.0
# and cmark-gfm through GitHub's own rendering API — and they agree row
# for row. The controls are the ones that separate this from "treat any
# short line as a list": a paragraph above turns the same `- ` back into
# a setext underline, a thematic break stays a thematic break in both its
# spellings, the content column still bounds indented code one column
# further in, and a non-blank-first item still survives two blank lines.
run_cm_matrix expect_rendered "Case 15o" \
  'four columns under a blank-first bullet is item prose|- \n    See [the audit](hub.md)' \
  'five columns is the last item-prose column|- \n     See [the audit](hub.md)' \
  'a BARE marker opens the same item|-\n    See [the audit](hub.md)' \
  'a tab after the marker still leaves no first child|-\t\n    See [the audit](hub.md)' \
  'a bare ordered marker takes its own wider column|1.\n      See [the audit](hub.md)' \
  'the paren spelling behaves identically|1)\n      See [the audit](hub.md)' \
  'the inner of two blank-first markers bounds the code|- -\n      See [the audit](hub.md)' \
  'an indented blank-first bullet shifts its column too|  - \n      See [the audit](hub.md)' \
  'a bare equals sign opens a paragraph, not a heading underline|=\n    See [the audit](hub.md)' \
  'an item that takes content on the next line keeps its frame|- \n- x\n    See [the audit](hub.md)' \
  'three columns after the closing blank is top-level prose|- \n\n   See [the audit](hub.md)' \
  'an item with content may still hold two blank lines|- # Item\n\n\n    See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15o" \
  'six columns under a blank-first bullet is item code|- \n      See [the audit](hub.md)' \
  'the same bound applies to a bare star marker|*\n      See [the audit](hub.md)' \
  'and to a bare plus marker|+\n      See [the audit](hub.md)' \
  'seven columns under a bare ordered marker is item code|1.\n       See [the audit](hub.md)' \
  'a second blank line closes the empty item|- \n\n    See [the audit](hub.md)' \
  'and what follows it is top-level indented code|- \n\n     See [the audit](hub.md)' \
  'the closing blank leaves the OUTER item standing|- -\n\n      See [the audit](hub.md)' \
  'eight columns is code inside the inner item|- -\n        See [the audit](hub.md)' \
  'a paragraph above makes the same line a setext underline|Governance\n- \n    See [the audit](hub.md)' \
  'a thematic break is not a blank-first item|---\n    See [the audit](hub.md)' \
  'nor is its spaced spelling|- - -\n    See [the audit](hub.md)'

# --- Case 15p: a dedented block quote closes the list it interrupts ---
# § Block quotes: "The block quote can interrupt a paragraph." That single
# sentence is what separates a block quote from indented code here, and the
# container stack was reading the two the same way.
#
# The stack is popped for a line that starts a new block at its own
# indentation, but only while no text flow is open — a guard against
# treating a lazy continuation as a dedent. A block quote is the one shape
# that guard must not cover: it is always a new block, and the paragraph it
# opens INSIDE itself was being read as evidence that the list outside it
# was still running. So `- para`, a column-zero `> quote`, a blank line and
# a four-column link kept the column-2 item frame alive, raised the code
# threshold to six, and reported as a link a line both renderers make
# top-level indented code — a false ownership failure, and the same one a
# dedented fence used to produce.
#
# The rows that pin the fix to block quotes rather than to dedents in
# general are the ones where the quote is still INSIDE the item: at the
# content column and one column past it the item survives and its own
# threshold still governs, and four columns past it the line is lazy
# continuation text that never had a quote depth to begin with, because
# `quote_depth` stops counting at a four-space run. A list living inside a
# quote is the mirror control — its frame carries the quote depth, so a
# deeper quote is not "deeper than the frame" and nothing pops.
#
# The last two rendered rows pin the comparison itself rather than the rule.
# A frame at quote depth zero is the common case, so relaxing the test from
# "deeper than the frame" to "as deep as the frame" makes it fire on EVERY
# unquoted line and the lazy-continuation guard stops existing: a dedented
# lazy line then a blank then item prose pops the frame, drops the threshold
# to four, and blanks as top-level code a line both renderers keep inside the
# item — the miss direction. Those two rows fail under that relaxation and
# pass under the rule as written.
#
# Every row was measured against BOTH renderers — markdown-it-py 4.2.0 and
# cmark-gfm through GitHub's own rendering API — and they agree row for row.
run_cm_matrix expect_rendered "Case 15p" \
  'three columns after a dedented quote is top-level prose|- para\n> quote\n\n   See [the audit](hub.md)' \
  'with no blank between, the same columns are quote continuation|- para\n> quote\n    See [the audit](hub.md)' \
  'a quote AT the content column stays inside the item|- para\n  > quote\n\n    See [the audit](hub.md)' \
  'and one column past it is still inside the item|- para\n   > quote\n\n    See [the audit](hub.md)' \
  'six columns in, the quote is lazy continuation text|- para\n      > quote\n\n    See [the audit](hub.md)' \
  'a marker inside a quote still carries its own content column|> - para\n>       See [the audit](hub.md)' \
  'a bullet after the closing blank is top-level again|- para\n> quote\n\n- See [the audit](hub.md)' \
  'no quote at all leaves the item paragraph open (control)|- para\n\n    See [the audit](hub.md)' \
  'an unquoted dedent is still a lazy continuation, not a pop|- para\nlazy\n\n    See [the audit](hub.md)' \
  'and the same holds under a wider marker|-   para\nlazy\n\n      See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15p" \
  'a dedented block quote closes the list it interrupts|- para\n> quote\n\n    See [the audit](hub.md)' \
  'it closes a nested list to the same depth|- - para\n> quote\n\n    See [the audit](hub.md)' \
  'a doubled quote marker closes it just the same|- para\n> > quote\n\n    See [the audit](hub.md)' \
  'six columns under a quote at the content column is item code|- para\n  > quote\n\n      See [the audit](hub.md)' \
  'eight columns is code whichever frame is standing|- - para\n> quote\n\n        See [the audit](hub.md)' \
  'a list INSIDE a quote dies with the quote, not with this rule|> - para\n>   more\n\n    See [the audit](hub.md)' \
  'a dedented heading closes the list the same way (control)|- para\n# Governance\n\n    See [the audit](hub.md)'

# --- Case 15q: a dedented FENCE closes the list under an open paragraph ---
# The same hole as Case 15p, on the shape the pop was originally written
# for. § Fenced code blocks: a fence can interrupt a paragraph, so a
# dedented opener is never a lazy continuation and must close the list it
# leaves. Behind the `text_flow_open` guard the pop only ever fired when
# nothing was open: after `- # Item` the heading closes the flow and the
# fence popped (Case 15i), but after `- para` the paragraph was still open,
# the column-2 frame survived a list the fence had already ended, and a
# four-column line both renderers make top-level indented code was reported
# as a link.
#
# So the opener is recognized BEFORE the pop instead of after it. The rows
# that keep it honest are the ones where the fence is NOT a dedent — at the
# item content column the item survives and its own six-column threshold
# still governs — and the two shapes that are not fences at all: a backtick
# in a backtick info string, and a run shorter than three.
#
# Every row was measured against BOTH renderers — markdown-it-py 4.2.0 and
# cmark-gfm through GitHub's own rendering API — and they agree row for row.
run_cm_matrix expect_rendered "Case 15q" \
  'three columns after a dedented fence is top-level prose|- para\n```\nx\n```\n\n   See [the audit](hub.md)' \
  'a fence AT the content column leaves the item standing|- para\n  ```\n  x\n  ```\n\n    See [the audit](hub.md)' \
  'a backtick in a backtick info string is prose, not a fence|- para\n``` a`b\n\n    See [the audit](hub.md)' \
  'and a two-character run is not a fence either|- para\n``\n\n    See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15q" \
  'a dedented fence closes the item under an open paragraph|- para\n```\nx\n```\n\n    See [the audit](hub.md)' \
  'the tilde spelling closes it the same way|- para\n~~~\nx\n~~~\n\n    See [the audit](hub.md)' \
  'it closes a nested item to the same depth|- - para\n```\nx\n```\n\n    See [the audit](hub.md)' \
  'six columns under a fence at the content column is item code|- para\n  ```\n  x\n  ```\n\n      See [the audit](hub.md)' \
  'a link inside the dedented fence is fence content|- para\n```\nSee [the audit](hub.md)\n```' \
  'a heading item still closes the same way (control)|- # Item\n```\nx\n```\n\n    See [the audit](hub.md)'

# --- Case 15r: quote depth is measured from the container, not column 0 ---
# § Block quotes allows up to three spaces of indentation before the `>`.
# That allowance is relative to the container the line arrives inside, and
# measuring it from column zero rejected a perfectly valid marker for
# sitting in an indented item: after `- para`, the line `    > - # inner`
# puts its `>` two columns into item content — well short of the six that
# would make it code — yet four ABSOLUTE spaces broke the count and the
# depth came back zero.
#
# The depth is not cosmetic: it is what a container frame is tagged with, so
# a list inside a quote dies when the quote does. Tagged at zero, the inner
# frame outlived the unmarked blank that ends the quote, raised the code
# threshold, and a six-column line both renderers render as indented code in
# the OUTER item was reported as a link.
#
# The base is the content column of the innermost container still standing
# from the previous line, and only as much of it as is really there — a line
# may be dedented below it and still open a quote. The top-level rows are
# the ones that keep the base from leaking: with no container, four spaces
# before a `>` is still indented code and not a quote.
#
# Every row was measured against BOTH renderers — markdown-it-py 4.2.0 and
# cmark-gfm through GitHub's own rendering API — and they agree row for row.
#
# The base is a COLUMN count, so the run that supplies it is measured in
# columns and a tab advances to the next tab stop. Accepting only literal
# spaces made the whole exception inert wherever the indentation was spelled
# with a tab, which is the pair of tab rows below.
run_cm_matrix expect_rendered "Case 15r" \
  'four columns after the quote closes is outer item prose|- para\n    > - # inner\n\n    See [the audit](hub.md)' \
  'a marked blank keeps the quote and its inner item alive|- para\n    > - # inner\n    >\n    >     See [the audit](hub.md)' \
  'the allowance follows a wider item too|-   para\n     > - # inner\n\n       See [the audit](hub.md)' \
  'a tab-spelled prefix, one column short of the threshold|-\tpara\n\t> - # inner\n\n\t   See [the audit](hub.md)' \
  'a tab inside the allowance, one column short|- para\n  \t> - # inner\n\n    See [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15r" \
  'a tab-spelled container prefix counts in columns too|-\tpara\n\t> - # inner\n\n\t    See [the audit](hub.md)' \
  'a tab INSIDE the three-column allowance counts too|- para\n  \t> - # inner\n\n      See [the audit](hub.md)' \
  'and a tab immediately after the base|- para\n\t> - # inner\n\n      See [the audit](hub.md)' \
  'and the same with no inner list to tag|-\tpara\n\t> quote\n\n\t    See [the audit](hub.md)' \
  'a tab-indented item with no quote at all (control)|-\tpara\n\n\t    See [the audit](hub.md)' \
  'a quote four columns inside an item is still a quote|- para\n    > - # inner\n\n      See [the audit](hub.md)' \
  'and so is one with no inner list to tag|- para\n    > quote\n\n      See [the audit](hub.md)' \
  'with NO container, four spaces is indented code (control)|    > quote\n\n    See [the audit](hub.md)' \
  'and still is when the line below it is deeper (control)|    > quote\n\n      See [the audit](hub.md)' \
  'three spaces at top level is a real quote (control)|   > quote\n\n    See [the audit](hub.md)'

# --- Case 15t: HTML-block separators are ASCII, and the ORACLE IS WRONG HERE ---
# The same locale-dependent `[[:space:]]` defect as Case 15s below, in the
# HTML-block conditions. § HTML blocks admits a space, a tab, a line ending,
# `>` or `/>` after the tag name, and under gawk in a UTF-8 locale
# `[[:space:]]` also matched Unicode separators. `<div<U+2003>>governance`
# therefore opened a condition-6 block under gawk and stayed prose under BWK
# awk and mawk, so the same document produced two different ownership verdicts.
#
# THESE ROWS DELIBERATELY BYPASS THE REFERENCE-RENDERER CROSS-CHECK, and that
# is the whole reason they are written out longhand instead of going through
# run_cm_matrix. This is the first place found where the two renderers
# themselves disagree on a row the checker has to decide:
#
#   markdown-it-py 4.2.0  opens the HTML block on U+2003  -> link NOT rendered
#   cmark-gfm (GitHub)    does not                        -> link RENDERED
#
# Measured on all three inputs through GitHub POST /markdown, mode gfm. The
# rule this PR adopted — agree with the renderer readers actually use, because
# the checker exists to predict where a reader following a link lands —
# settles it for cmark-gfm, so the checker is ASCII-only and these rows assert
# the cmark-gfm verdict. Running them through the oracle would fail them
# against markdown-it-py, which is a disagreement about the target parser and
# not a defect in either the rows or the checker.
#
# This is the exemption #929 item 25 predicted would eventually be needed. It
# is confined to the rows where the divergence is measured, and every other row
# in this file still goes through the oracle. The rows run under the UTF-8
# locale pin below, alongside Case 15s, because they turn on the identical gawk
# ctype behaviour and would be equally inert under LC_ALL=C.
cm_15t() {
  local label="$1" body="$2" verdict="$3"
  local out rc
  set +e
  out=$(run_truth_body "$body")
  rc=$?
  set -e
  "$verdict" "Case 15t: $label" "$rc" "$out"
}

# --- Case 15s: the marker run is spaces and tabs, not [[:space:]] ---
# § List items allows only spaces and tabs after a list marker, and
# list_marker_columns consumes only those two. The classifier spelled the
# same trailer `[[:space:]]`, and the two are not the same set: under gawk in
# a UTF-8 locale `[[:space:]]` also matches Unicode whitespace, while BWK awk
# and mawk are byte-oriented and do not.
#
# So `-<U+2003># Heading` entered the list branch under gawk only, measured a
# zero-column marker, closed the text flow, and blanked the line under it —
# MISSING a hub-only reference that BWK awk and mawk both reported, and both
# renderers render. A check whose verdict depends on which awk CI happens to
# run is worse than one that is uniformly wrong, and this suite runs under
# all three precisely to catch that.
#
# Six columns is the discriminating depth: under a REAL marker run that is
# item code and the link does not render, and under a non-marker it is a lazy
# continuation of an ordinary paragraph and the link does. The tab row is the
# control on the other side — a tab IS a valid marker run and must keep
# behaving like one.
#
# THESE ROWS ONLY TEST ANYTHING UNDER A UTF-8 LOCALE. The behaviour they pin is
# gawk reading `[[:space:]]` against the ctype table of the running locale, and
# under `LC_ALL=C` gawk sees the em space as three separate bytes and matches
# none of them. Measured: piping U+2003 to gawk reports `length=3
# space_match=0` under `LC_ALL=C` and `length=1 space_match=1` under
# `en_US.UTF-8`. Left to the ambient locale the rows would pass in C with the
# defect fully restored — verified by re-running the revert mutation under
# `LC_ALL=C` with gawk, where it kills nothing and the suite is green. So the
# locale is pinned for the duration of this case, and when the runner offers no
# UTF-8 locale at all the case is SKIPPED WITH THE REASON NAMED rather than run
# vacuously green, the same contract the reference-renderer gate above uses.
CM_UTF8_LOCALE=""
for cand in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qxF "$cand"; then CM_UTF8_LOCALE="$cand"; break; fi
done
if [ -z "$CM_UTF8_LOCALE" ]; then
  CM_UTF8_LOCALE=$(locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -1)
fi
if [ -z "$CM_UTF8_LOCALE" ]; then
  echo "NOTE: Cases 15s and 15t SKIPPED — no UTF-8 locale on this runner, so" \
       "gawk cannot match U+2003 with [[:space:]] and these rows would pass" \
       "vacuously." >&2
else
  cm_saved_lc_all="${LC_ALL-}"
  cm_saved_lc_ctype="${LC_CTYPE-}"
  cm_saved_lang="${LANG-}"
  export LC_ALL="$CM_UTF8_LOCALE" LC_CTYPE="$CM_UTF8_LOCALE" LANG="$CM_UTF8_LOCALE"

  run_cm_matrix expect_rendered "Case 15s" \
    'an em space after a hyphen is not a marker run|-\xe2\x80\x83# Heading\n      See [the audit](hub.md)' \
    'nor after a star|*\xe2\x80\x83# Heading\n      See [the audit](hub.md)' \
    'nor after an ordered marker|1.\xe2\x80\x83# Heading\n      See [the audit](hub.md)' \
    'a tab after the marker IS a run and sets its column (control)|-\t# Heading\n      See [the audit](hub.md)'

  run_cm_matrix expect_not_rendered "Case 15s" \
    'a plain space after the marker is a run, so six columns is item code|- # Heading\n      See [the audit](hub.md)'

  # Case 15u: the rest of the block classifier, swept in one pass instead of
  # one site per review round. Every [[:space:]] inside the renderable-text awk
  # program is now the ASCII set, because CommonMark defines block structure in
  # terms of spaces and tabs and a line ending cannot occur inside a line — so
  # the POSIX class only ever added locale-dependent Unicode matches that made
  # the verdict depend on which awk CI ran. Twelve sites moved; these rows
  # cover the ones a document can actually reach, one per rule:
  #
  #   the list-interruption test  a nonblank item CAN interrupt a paragraph,
  #                               and an em space is content, not blankness
  #   thematic break              spaces and tabs may be interspersed, an em
  #                               space is not, so the line stays a paragraph
  #   ATX heading                 the run after the hashes is a space or tab
  #   blank line                  only spaces and tabs make a line blank
  #   setext underline            only spaces and tabs may trail it
  #   fenced code closer          only spaces and tabs may trail it
  #
  # Each row is written so the em space FLIPS the verdict — the construct is
  # recognized with ASCII whitespace and not with the em space — which is what
  # makes it fail under the old spelling instead of passing either way. That
  # is not automatic: a first draft of the blank-line, setext and fence rows
  # put the em space somewhere the two spellings agreed, and reverting the
  # whole sweep left all three green. Each now carries the ASCII control that
  # proves the pair really does discriminate.
  run_cm_matrix expect_rendered "Case 15u" \
    'an em space after a valid marker separator is item content|Governance\n- \xe2\x80\x83\n\n    See [the audit](hub.md)' \
    'an em space between dashes is not a thematic break|Governance\n- \xe2\x80\x83-\xe2\x80\x83-\n\n    See [the audit](hub.md)' \
    'an em space after the hashes is not an ATX heading|#\xe2\x80\x83Governance\n    See [the audit](hub.md)' \
    'a line of only an em space does not close a blank-first item|- \n\xe2\x80\x83\n    See [the audit](hub.md)' \
    'a trailing em space is not a setext underline|Governance\n===\xe2\x80\x83\n    See [the audit](hub.md)' \
    'an ASCII trailing space DOES close a fence (control)|- para\n```\nx\n``` \nSee [the audit](hub.md)'

  run_cm_matrix expect_not_rendered "Case 15u" \
    'an ASCII-only separator really does leave the item blank (control)|Governance\n- \n\n    See [the audit](hub.md)' \
    'six columns under the same interrupted paragraph (control)|Governance\n- \xe2\x80\x83\n\n      See [the audit](hub.md)' \
    'a real blank line DOES close a blank-first item (control)|- \n\n    See [the audit](hub.md)' \
    'an ASCII trailing space IS a setext underline (control)|Governance\n=== \n    See [the audit](hub.md)' \
    'a trailing em space does not close a fence|- para\n```\nx\n```\xe2\x80\x83\nSee [the audit](hub.md)'

  # Case 15t rides the same pin: its rows turn on the identical gawk ctype
  # behaviour, so under LC_ALL=C they would be just as inert.
  cm_15t 'an em space after a tag name is not an HTML-block separator' \
    '<div\xe2\x80\x83>governance\n    See [the audit](hub.md)' expect_rendered
  cm_15t 'nor after a condition-1 tag name' \
    '<pre\xe2\x80\x83>governance\n    See [the audit](hub.md)' expect_rendered
  cm_15t 'nor before an attribute' \
    '<div\xe2\x80\x83class=x>\n    See [the audit](hub.md)' expect_rendered
  cm_15t 'a plain space IS a separator (control)' \
    '<div >governance\n    See [the audit](hub.md)' expect_not_rendered
  cm_15t 'and so is a tab (control)' \
    '<div\t>governance\n    See [the audit](hub.md)' expect_not_rendered

  # Restored rather than left set: every case after this one is tuned to the
  # ambient locale, and several turn on whether the running awk counts bytes or
  # code points.
  if [ -n "$cm_saved_lc_all" ]; then export LC_ALL="$cm_saved_lc_all"; else unset LC_ALL; fi
  if [ -n "$cm_saved_lc_ctype" ]; then export LC_CTYPE="$cm_saved_lc_ctype"; else unset LC_CTYPE; fi
  if [ -n "$cm_saved_lang" ]; then export LANG="$cm_saved_lang"; else unset LANG; fi
fi

# --- Case 15v: a CRLF document classifies exactly like an LF one -----
# § Preliminaries: a line ending is a newline, a carriage return, or a carriage
# return + newline, and it is NOT part of the line. awk splits on the newline
# only, so a CRLF document hands every rule a trailing CR.
#
# These rows exist because narrowing the whitespace classes to ASCII BROKE
# CRLF documents, and nothing in the suite noticed. While the classes were
# `[[:space:]]` the stray CR was being absorbed by them invisibly; once they
# became `[ \t]` — the set the spec actually defines — a CRLF blank line
# stopped reading as blank, a fence closer with a trailing CR stopped closing
# its fence, and a link after that fence was scanned as code and MISSED. The
# fix is to normalize the line ending once at input rather than to widen the
# classes back, because a line ending is not horizontal whitespace.
#
# The rows are written as PAIRS against their LF twins, and the pairing is the
# assertion: whatever the LF spelling decides, the CRLF spelling must decide
# identically. They deliberately do not go through the reference renderer,
# because `printf '%b'` + the oracle would compare a different pair of inputs
# than the checker sees; the LF twin IS the oracle here, and each twin is
# itself an oracle-checked row elsewhere in Cases 15o–15u.
cm_15v() {
  local label="$1" body="$2" verdict="$3"
  local out rc
  set +e
  out=$(run_truth_body "$body")
  rc=$?
  set -e
  "$verdict" "Case 15v: $label" "$rc" "$out"
}

cm_15v 'a CRLF blank line still closes the text flow' \
  '- para\r\n\r\n      See [the audit](hub.md)\r' expect_not_rendered
cm_15v 'and four columns under it is still item prose' \
  '- para\r\n\r\n    See [the audit](hub.md)\r' expect_rendered
cm_15v 'a CRLF heading still dedents and closes the item' \
  '- para\r\n# Governance\r\n\r\n    See [the audit](hub.md)\r' expect_not_rendered
cm_15v 'a CRLF fence closer still closes its fence' \
  '- para\r\n```\r\nx\r\n```\r\nSee [the audit](hub.md)\r' expect_rendered
cm_15v 'a CRLF setext underline still closes the paragraph' \
  'Governance\r\n===\r\n    See [the audit](hub.md)\r' expect_not_rendered
cm_15v 'and a plain CRLF link is still seen' \
  'See [the audit](hub.md)\r' expect_rendered

# --- Case 15w: a deeply nested marker line still yields a VERDICT ----
# What these rows pin is not a misclassification, it is the ABSENCE of an
# answer. The classifier used to consume list markers by tail-calling itself
# once per marker, so a line of many markers cost the required gate its
# verdict — and WHICH way it did so depended on the awk, which is the worst
# property a gate can have. Measured on this tree before the fix, with `- `
# repeated N times:
#
#   BWK awk 20200816   segfaults from N=7000 (N=6500 still answers)
#   mawk 1.3.4         answers; this build grows its eval stack, while the
#                      build #929 item 33 was measured on dies at ~N=500 with
#                      `program limit exceeded: eval stack size=1024`
#   gawk 5.4.1         answers, but took 278s at N=5000 and climbed
#
# And the crash is worse than "no verdict", which is how item 33 described it.
# Measured by restoring the recursion and running N=7000 under BWK awk: the
# check exits 0 and reports a clean PASS. Every producer in the extractor
# carries `|| true` — deliberately, so a no-match grep cannot abort the group
# — so a classifier that dies mid-pipeline yields no targets and check 10
# concludes there is nothing to report. The gate does not go red on a document
# it could not read; it goes GREEN.
#
# WHAT THESE ROWS DO AND DO NOT DISCRIMINATE, stated plainly because the
# honest answer is interpreter-dependent.
#
# Two 150-marker rows pin the marker bound from both sides, because a bound is
# a behaviour change and an untested one drifts. Both put a line at 210
# columns under 150 markers — past 2x the bound, short of 2x the true depth —
# and they differ only in whether a BLANK LINE separates the two.
#
#   PRESENCE (with the blank). The bound puts the content column at 2x100;
#   unbounded it would be 2x150, and 210 falls between, so the line is
#   indented code with the bound and item prose without it. Both renderers
#   make it code, so this row goes through the ORACLE: the bound is not a
#   divergence here, it is CLOSER to both renderers than the unbounded reading
#   was, because neither tracks nesting that deep either. Deleting the bound
#   flips this row on all three awks.
#
#   DIRECTION (no blank). The bound declares text flow OPEN where it stops, so
#   the 210-column line is lazy continuation text and its link is scanned. A
#   bound that closed the flow instead would blank it and MISS the reference —
#   and that mutation is invisible to every other shape, including a link
#   sitting on the marker line itself, which is printed either way because the
#   blanking only ever reaches the lines that FOLLOW a marker.
#
# The 2000-marker row is the crash row, and N=2000 is chosen so it costs every
# awk here under three seconds. On THIS machine it is a verdict-and-cost row:
# neither BWK awk (which crashes only from 7000) nor this mawk build fails at
# 2000 without the fix. On the mawk builds carrying the fixed 1024-entry eval
# stack — the `awk` a Debian or Ubuntu CI runner selects by default, and the
# build item 33 was reported from — it is a live crash regression, because
# 2000 markers is four times that stack. The depth that crashes BWK awk HERE
# is deliberately not used: a 14000-character line costs gawk 84 seconds in
# the destination extractor, whose superlinear cost in LINE LENGTH is a
# separate defect — just as slow on a marker line carrying no link at all —
# filed on #929 rather than fixed here.
#
# TWO ROWS DELIBERATELY BYPASS THE REFERENCE-RENDERER CROSS-CHECK — the
# direction row and the 2000-marker row — for the Case 15t reason and with the
# same longhand treatment. Past nine markers the two renderers disagree,
# because markdown-it-py has an implementation nesting cap and cmark-gfm does
# not:
#
#   markdown-it-py 4.2.0  maxNesting=20, two levels per marker, so from TEN
#                         markers up it stops and the link is NOT rendered
#   cmark-gfm (GitHub)    renders the link at every depth measured — 1, 2, 19,
#                         20, 21, 30, 99, 100, 101, 150, 200, 500, 5000 and
#                         10000, `href="hub.md"` present in every response. It
#                         caps its OUTPUT at ten <ul> levels and makes the
#                         rest siblings; the link still resolves.
#
# Measured through GitHub POST /markdown, mode gfm. The rule this PR adopted —
# agree with the renderer readers actually use — settles it for cmark-gfm, so
# the checker must CLAIM the link, which is what those two rows assert. The
# five-marker row is under BOTH renderers' caps and the with-blank row is one
# both renderers agree on, so those two go through the oracle like every other
# row in this file.
cm_repeat() {
  # `$2` repeated `$1` times, built by doubling: a two-thousand-marker body is
  # a handful of string concatenations rather than two thousand loop turns.
  local n="$1" unit="$2" out=""
  while [ "$n" -gt 0 ]; do
    if [ $((n % 2)) -eq 1 ]; then out="$out$unit"; fi
    unit="$unit$unit"
    n=$((n / 2))
  done
  printf '%s' "$out"
}
cm_markers() { cm_repeat "$1" '- '; }
cm_spaces() { cm_repeat "$1" ' '; }

cm_15w() {
  local label="$1" body="$2" verdict="$3"
  local out rc
  set +e
  out=$(run_truth_body "$body")
  rc=$?
  set -e
  "$verdict" "Case 15w: $label" "$rc" "$out"
}

run_cm_matrix expect_rendered "Case 15w" \
  "five markers is an ordinary nested item (control)|$(cm_markers 5)See [the audit](hub.md)"

# 210 columns: past 2x the bound, short of 2x the true depth. Both
# markdown-it-py 4.2.0 and cmark-gfm make this indented code and render no
# link, so the oracle rules on it.
run_cm_matrix expect_not_rendered "Case 15w" \
  "the bound is the content column past it too|$(cm_markers 150)para\n\n$(cm_spaces 210)See [the audit](hub.md)"

cm_15w 'the bound leaves the text flow OPEN, so the line below it is scanned' \
  "$(cm_markers 150)para\n$(cm_spaces 210)See [the audit](hub.md)" expect_rendered
cm_15w 'two thousand markers still produce a verdict, and still claim the link' \
  "$(cm_markers 2000)See [the audit](hub.md)" expect_rendered

# --- Case 15x: a named reference the table cannot expand is REPORTED ---
# #929 item 31, the one gap in the extractor that pointed the wrong way. The
# named-reference tables hold ASCII, Latin-1 Supplement and Latin Extended-A;
# HTML5 defines about 2100 more names. A destination carrying one of those
# used to be compared in its still-ENCODED spelling, which matches no
# inventory path — so the reference was silently permitted while every reader
# followed it. Greek, math and the arrows are all in that gap.
#
# Both renderers agree on every input below, so there is no oracle bypass
# here; they are written longhand only because the fixture needs a hub-only
# doc named with the DECODED character, which the shared `hub.md` fixture
# cannot be. Measured with markdown-it-py 4.2.0 and with cmark-gfm through
# GitHub POST /markdown, mode gfm:
#
#   [the audit](&alpha;.md)        both: href="%CE%B1.md"
#   [the audit](&#945;.md)         both: href="%CE%B1.md"
#   [the audit](&aacute;.md)       both: href="%C3%A1.md"
#   [the audit](&amp;alpha;.md)    both: href="&amp;alpha;.md"
#   [the audit](&notaname;.md)     both: href="&amp;notaname;.md"
#
# THE TRIGGER IS DELIBERATELY WIDER THAN HTML5, and the `&perio;` row is where
# that shows. Both renderers leave `&perio;` literal — it is a near-miss of
# `&period;` and not a name at all — so the checker reporting it is a FALSE
# POSITIVE, and it used to be a clean row in Case 14v asserting exactly that.
# It moved here deliberately: telling a real name apart from a plausible
# non-name needs precisely the 2100-entry table this avoids embedding, and
# between a false positive an author can fix in one edit and a MISS nobody
# ever sees, a guardrail takes the false positive. Two exact spellings are
# offered in the diagnostic, and both are pinned by rows below: the numeric
# reference for a character, `&amp;` for a literal ampersand.
#
# The bound that costs nothing is kept: HTML5 defines no single-character
# name, so `&x;` cannot be one, and neither can a body carrying a character
# outside the name class. Both stay literal and both keep their Case 14v rows.
CM_UNRESOLVED_TAIL="which carries a named character reference this check cannot expand — the destination a reader opens is therefore unknown, and it cannot be compared against the hub-only inventory. Write the character itself, or its numeric reference (&#NNN; or &#xHH;), both of which are decoded in full; if the text is meant literally, spell the ampersand &amp;."

# The destination is unverifiable, so the run must report exactly that, once,
# quoting the destination as written — and nothing else alongside it.
expect_unresolvable() {
  local label="$1" rc="$2" out="$3" dest="$4"
  local want="FAIL: canonical doc 'docs/agents/shared.md' has the link destination '$dest', $CM_UNRESOLVED_TAIL"
  local exact total
  exact=$(printf '%s\n' "$out" | grep -cxF -- "$want" || true)
  total=$(printf '%s\n' "$out" | grep -c '^FAIL: ' || true)
  if [ "$rc" = "1" ] && [ "$exact" = "1" ] && [ "$total" = "1" ]; then
    pass "$label"
  else
    fail "$label (rc=$rc exact=$exact total=$total): $out"
  fi
}

# One canonical-doc body against a two-doc fixture whose hub-only doc is NAMED
# BY THE CALLER, so a destination that decodes to a non-ASCII name has
# something to resolve to. U+03B1 and U+00E1 both have stable NFC/NFD
# spellings for this fixture: the Greek letter has no decomposition at all,
# and the row that uses the accented one is the row where the table already
# resolves it, so a normalizing filesystem cannot change either verdict.
run_named_hub_body() {
  local hub="$1" body="$2"
  run_with_doc_bodies "$(ENTITY_MANIFEST "docs/agents/$hub")" \
    "docs/agents/shared.md|$body
docs/agents/$hub|# Hub-only machinery"
}

cm_15x() {
  local label="$1" hub="$2" body="$3" verdict="$4" arg="${5:-}"
  local out rc
  set +e
  out=$(run_named_hub_body "$hub" "$body")
  rc=$?
  set -e
  "$verdict" "Case 15x: $label" "$rc" "$out" "$arg"
}

cm_15x 'a name outside the tables is reported, not permitted' \
  'α.md' 'See [the audit](&alpha;.md) for details.' \
  expect_unresolvable '&alpha;.md'
cm_15x 'the same character as a numeric reference still resolves' \
  'α.md' 'See [the audit](&#945;.md) for details.' \
  expect_rendered 'docs/agents/α.md'
cm_15x 'and so does the character written literally' \
  'α.md' 'See [the audit](α.md) for details.' \
  expect_rendered 'docs/agents/α.md'
cm_15x 'a name the table DOES hold is unaffected' \
  'á.md' 'See [the audit](&aacute;.md) for details.' \
  expect_rendered 'docs/agents/á.md'
cm_15x 'an escaped ampersand is a literal, and reports nothing' \
  'α.md' 'See [the audit](&amp;alpha;.md) for details.' \
  expect_not_rendered
cm_15x 'the same name in prose is not a destination' \
  'α.md' 'The letter &alpha; is used in prose only.' \
  expect_not_rendered
cm_15x 'a reference DEFINITION destination is covered too' \
  'α.md' '[the audit]: &alpha;.md\n\nSee [the audit] for details.' \
  expect_unresolvable '&alpha;.md'
cm_15x 'and so is an angle-bracket destination' \
  'α.md' 'See [the audit](<&alpha;.md>) for details.' \
  expect_unresolvable '<&alpha;.md>'
# The diagnostic quotes the destination AS WRITTEN, which for the angle form
# is the wrapper and not the rest of the line. A reference definition may
# carry a title after it, and the bare branch trims at the first space, so
# without the matching trim the message named `<x.md> "Title"` as a
# destination nobody wrote (CodeRabbit, #925).
cm_15x 'the angle form is trimmed to the wrapper, title excluded' \
  'α.md' '[the audit]: <&alpha;.md> "Title"\n\nSee [the audit] for details.' \
  expect_unresolvable '<&alpha;.md>'
cm_15x 'a plausible non-name is reported too, deliberately' \
  'hub.md' 'See [the audit](hub&perio;.md) for details.' \
  expect_unresolvable 'hub&perio;.md'
# Only the PATH is compared against the inventory, so only an unexpandable
# name in the PATH makes a destination unverifiable. Both renderers resolve
# `hub.md#&alpha;section` to `hub.md#%CE%B1section` — the fragment changes, the
# path does not — so reporting it would be a false positive on a link that
# resolves perfectly (CodeRabbit, #925). The four rows pin both sides of the
# delimiter, and the first two also prove the PATH comparison still runs: they
# reach the hub-only doc and must be reported as THAT, not as unverifiable.
cm_15x 'a name in the fragment leaves the path verifiable' \
  'hub.md' 'See [the audit](hub.md#&alpha;x) for details.' \
  expect_rendered 'docs/agents/hub.md'
cm_15x 'and so does one in the query' \
  'hub.md' 'See [the audit](hub.md?&alpha;=1) for details.' \
  expect_rendered 'docs/agents/hub.md'
cm_15x 'a name in the path is still reported, fragment or not' \
  'α.md' 'See [the audit](&alpha;.md#x) for details.' \
  expect_unresolvable '&alpha;.md#x'
cm_15x 'and with a query after it' \
  'α.md' 'See [the audit](&alpha;.md?a=1) for details.' \
  expect_unresolvable '&alpha;.md?a=1'
# A destination check 10 never compares cannot hide anything either, so an
# unexpandable name inside one is not worth reporting — and reporting it would
# block a portable canonical doc for no gain (Codex P2 on #925). The four rows
# cover every arm of the skip list the resolved-target loop already uses:
# absolute scheme, mailto, protocol-relative, and a name in the query of an
# absolute URL. The relative rows above are the discriminating control.
cm_15x 'a name in an absolute URL path is not reported' \
  'hub.md' 'See [external](https://example.com/&alpha;/x) for details.' \
  expect_not_rendered
cm_15x 'nor one in its query' \
  'hub.md' 'See [external](https://example.com/?x=&alpha;) for details.' \
  expect_not_rendered
cm_15x 'nor one in a mailto destination' \
  'hub.md' 'See [mail](mailto:&alpha;@example.com) for details.' \
  expect_not_rendered
cm_15x 'nor one in a protocol-relative destination' \
  'hub.md' 'See [p](//host/&alpha;/x) for details.' \
  expect_not_rendered
# The flag is per-DESTINATION, and every destination in the document runs
# through the same awk process. Dropping its reset would make the first
# unresolvable destination condemn every one after it, which no other row can
# see: this one carries a clean second link, so the count of failures is the
# assertion.
cm_15x 'the flag does not leak to the destination after it' \
  'hub.md' 'See [the audit](x&perio;.md) and [the other](other.md).' \
  expect_unresolvable 'x&perio;.md'

# --- Case 15y: a fence is recognised RELATIVE to its container -------
# #929 item 29. § Fenced code blocks allows a fence "indented by up to three
# spaces", and like every other allowance in the spec that is measured from
# the CONTENT COLUMN of the container the line arrives inside, not from column
# zero. Measuring it absolutely made a fence at the content column of a wide
# ordered item, or after a block-quote marker, invisible — so both renderers
# put the link inside a code block and this program scanned it as prose. Two
# false ownership failures, plus two more the same fix reaches.
#
# Every row here is checked against markdown-it-py by run_cm_matrix AND was
# measured against cmark-gfm through GitHub POST /markdown, mode gfm. The two
# renderers agree on all of them, so there is no bypass in this case.
#
# The rows come in pairs on purpose. A fence that is recognised must also be
# CLOSED at the same relative indent, or the fix trades a false positive for a
# swallowed document: the `not rendered` row of each pair puts the link INSIDE
# the fence, and the `rendered` row puts it after the closer.
run_cm_matrix expect_not_rendered "Case 15y" \
  'a fence at the content column of a wide ordered item|10. para\n    ```\n    See [the audit](hub.md)\n    ```' \
  'a fence after a block-quote marker|> ```\n> See [the audit](hub.md)\n> ```' \
  'and one two columns into a bullet item|- para\n    ```\n    See [the audit](hub.md)\n    ```' \
  'content four columns inside a quoted fence is its code|> ```\n>     See [the audit](hub.md)\n> ```' \
  'a column-zero fence still swallows its content (control)|```\nSee [the audit](hub.md)\n```' \
  'three spaces at top level is still a fence (control)|   ```\n   See [the audit](hub.md)\n   ```' \
  'four spaces at top level is indented code (control)|    ```\n    See [the audit](hub.md)\n    ```'

run_cm_matrix expect_rendered "Case 15y" \
  'the ordered-item fence CLOSES, so the line after it is prose|10. para\n    ```\n    x\n    ```\n    See [the audit](hub.md)' \
  'the quoted fence closes too|> ```\n> x\n> ```\n>\n> See [the audit](hub.md)' \
  'and the bullet-item one|- para\n    ```\n    x\n    ```\n    See [the audit](hub.md)' \
  'four columns into a quote is NOT a fence, so the link renders|>     ```\n> See [the audit](hub.md)' \
  'a column-zero fence closes at column zero (control)|```\nx\n```\nSee [the audit](hub.md)'

# --- Case 15aa: an HTML block is carried PAST its opener ------------
# #929 item 28. § HTML blocks gives each of the seven start conditions its own
# END condition, and only the openers were recognised — nothing closed a block,
# so every line after one was scanned as Markdown and a link between `<div>`
# and `</div>` was reported although both renderers leave the whole thing raw.
# A false ownership failure, and the natural completion of the #811 work.
#
# The seven conditions collapse into five terminator classes, and there is one
# row per class plus the pairing control that proves the block actually ENDS:
#
#   1  <script> <pre> <style> <textarea>  a line containing the closing tag
#   2  <!--                               a line containing -->
#   3  <?                                 a line containing ?>
#   4  <! + a letter                      a line containing >
#   5  <![CDATA[                          a line containing ]]>
#   6  a block tag name                   a BLANK line
#   7  a complete tag alone on the line   a BLANK line
#
# The difference between the two groups is not cosmetic and both directions
# are pinned: for 1 to 5 the line carrying the closer is PART of the block,
# and a blank line does NOT end them — `<script>`, a blank, a link, `</script>`
# renders no link, which is the row that fails if types 1 to 5 are given the
# blank-line rule by mistake. For 6 and 7 the blank ends the block and is not
# part of it, so the link after it renders.
#
# Every row is checked against markdown-it-py by run_cm_matrix AND was
# measured against cmark-gfm through GitHub POST /markdown, mode gfm. The two
# agree on all thirteen, so nothing here bypasses the oracle.
run_cm_matrix expect_not_rendered "Case 15aa" \
  'type 6: a link between a block tag and its closer|<div>\nSee [the audit](hub.md)\n</div>' \
  'type 1: and inside a script block|<script>\nSee [the audit](hub.md)\n</script>' \
  'type 2: and inside a comment|<!--\nSee [the audit](hub.md)\n-->' \
  'type 3: and inside a processing instruction|<?\nSee [the audit](hub.md)\n?>' \
  'type 4: and inside a declaration|<!A\nSee [the audit](hub.md)\n>' \
  'type 5: and inside a CDATA section|<![CDATA[\nSee [the audit](hub.md)\n]]>' \
  'a blank line does NOT end a type 1 block|<script>\n\nSee [the audit](hub.md)\n</script>' \
  'the opener line carries block content, not Markdown|<div>See [the audit](hub.md)' \
  'type 7: a complete tag alone opens a block too|<span>\nSee [the audit](hub.md)' \
  'a quoted block still swallows its own quoted content|> <script>\n> See [the audit](hub.md)\n> </script>'

# An HTML block lives inside a CONTAINER, and both ways of leaving that
# container end it. These rows are the MISS direction, which is why they were
# worth another round: a state machine that keeps blanking after the block is
# over deletes rendered links from the scan, and the first version of this
# case had exactly that defect (Codex P2 on #925).
#
#   the terminator is tested against block CONTENT, so a MARKED blank (a line
#   holding only `>`) ends a quoted type 6 block; passing the raw line to the
#   whitespace test never matched and the block ran on
#   the CONTAINER closing ends it with no closer of its own, so an unquoted
#   line after `> <script>` is ordinary Markdown again
run_cm_matrix expect_rendered "Case 15aa" \
  'a marked blank ends a quoted type 6 block|> <div>\n>\n> See [the audit](hub.md)' \
  'leaving the quote ends the block it held|> <script>\nSee [the audit](hub.md)' \
  'and an unmarked blank does both at once|> <div>\n\nSee [the audit](hub.md)' \
  'a blank line DOES end a type 6 block (control)|<div>\n\nSee [the audit](hub.md)' \
  'and the link after a closed type 6 block renders|<div>\nx\n</div>\n\nSee [the audit](hub.md)' \
  'the line after a type 1 closer is Markdown again|<script>\nx\n</script>\nSee [the audit](hub.md)' \
  'a plain paragraph link is untouched by any of this (control)|See [the audit](hub.md)'

# --- Case 15ab: blocks opened by a list item close with that item ------
# An HTML block and a fenced block are first children just like headings or
# paragraphs. Each therefore inherits the list container that holds its marker:
# an unindented line after `- <script>` is ordinary top-level Markdown, while
# a fence after `- ` keeps its indented contents as code. The rows also pin the
# two paths the extractor takes to get there: HTML state must remember its
# opener's list frame, and list-item classification must carry a fence opener.
run_cm_matrix expect_rendered "Case 15ab" \
  'leaving a list closes its contained type 1 HTML block|- <script>\nSee [the audit](hub.md)'

run_cm_matrix expect_not_rendered "Case 15ab" \
  'a fence first child of a list item swallows its contents|- ```\n  See [the audit](hub.md)\n  ```'

# Backslash escapes are ASCII punctuation only. A full-width stop is not an
# escape target, so the literal backslash remains in the rendered destination;
# treating a locale's Unicode punctuation class as CommonMark punctuation can
# otherwise report a hub-only name on gawk that a reader never follows.
cm_15x 'a backslash before non-ASCII punctuation stays literal' \
  'hub。.md' 'See [the audit](hub\。.md) for details.' \
  expect_not_rendered

# --- Case 15z: an extractor that cannot read the doc FAILS the check ---
# Check 10 reasons entirely from the extractor's output, so "no output" and
# "no links" are the same string and the second one is a PASS. Every producer
# used to carry `|| true` and the final `grep -v` supplied the exit status, so
# a classifier that DIED produced an empty inventory and the check reported a
# clean pass on a document nobody could read. That is not hypothetical: it is
# what the recursion mutation in Case 15w does at 7000 markers under BWK awk.
#
# Marker-depth is not a portable way to provoke it — the crashing interpreter
# and depth are build-specific, and the depths that crash one awk cost another
# a minute and a half. An UNREADABLE FILE provokes the identical failure in
# every awk in milliseconds: the file exists, so check 3b does not report it
# and the loop does not skip it, and awk exits non-zero trying to open it.
#
# Skipped with the reason named when the chmod does not bite, which is what
# happens in a container running as root.
cm_unreadable_fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
mkdir -p "$cm_unreadable_fix/docs/agents" "$cm_unreadable_fix/scripts"
: > "$cm_unreadable_fix/scripts/sync-to-downstream.sh"
printf '%s' "$MANIFEST_TRUTH" > "$cm_unreadable_fix/manifest.yml"
printf '%s\n' 'See [the audit](hub.md) for details.' \
  > "$cm_unreadable_fix/docs/agents/shared.md"
printf '%s\n' '# Hub-only machinery' > "$cm_unreadable_fix/docs/agents/hub.md"
chmod 000 "$cm_unreadable_fix/docs/agents/shared.md"
if [ -r "$cm_unreadable_fix/docs/agents/shared.md" ]; then
  echo "NOTE: Case 15z SKIPPED — chmod 000 left the file readable (running as" \
       "root?), so the extractor cannot be made to fail here." >&2
  echo "test_check_doc_ownership: Case 15z SKIPPED (file still readable after chmod 000; extractor failure NOT verified)"
else
  set +e
  out=$(MERGEPATH_MANIFEST_PATH="$cm_unreadable_fix/manifest.yml" \
        MERGEPATH_REPO_ROOT="$cm_unreadable_fix" bash "$CHECK" 2>&1)
  rc=$?
  set -e
  want="FAIL: canonical doc 'docs/agents/shared.md' could not be scanned for link targets — the Markdown extractor exited non-zero, so its link inventory is unknown and this doc was NOT checked against the hub-only inventory. Re-run the check; if it repeats, the document is hitting a limit of the extractor and belongs on an issue rather than in a silent pass."
  exact=$(printf '%s\n' "$out" | grep -cxF -- "$want" || true)
  if [ "$rc" = "1" ] && [ "$exact" = "1" ]; then
    pass "Case 15z: an unreadable canonical doc fails the check instead of passing it"
  else
    fail "Case 15z (rc=$rc exact=$exact): $out"
  fi
fi
chmod 644 "$cm_unreadable_fix/docs/agents/shared.md" 2>/dev/null || true

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
# Say on STDOUT whether the CommonMark oracle actually ran, and when it did
# not, why. Without this the only trace is a stderr note, so an environment
# whose renderer is missing or targets another spec version reports a clean
# pass that silently skipped every cross-check — the matrix would be back to
# confirming that the checker agrees with expectations written by the same
# hand. The propagated repo_lint job is such an environment today (tracked in
# #929): it installs nothing, so its renderer is whatever the runner carries.
# Printing the reason is what keeps a green run from being mistaken for a
# verified one, and distinguishes "no renderer here" from "the renderer here
# answers a different specification".
if [ "${CM_ORACLE_READY:-0}" = "1" ]; then
  echo "test_check_doc_ownership: CommonMark oracle ACTIVE (rows cross-checked against markdown-it-py)"
else
  echo "test_check_doc_ownership: CommonMark oracle SKIPPED (${CM_ORACLE_SKIP_REASON:-unavailable}; rows NOT cross-checked)"
fi
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_doc_ownership: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_doc_ownership: PASS ($TOTAL tests)"
exit 0
