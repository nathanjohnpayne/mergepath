#!/usr/bin/env bash
# tests/test_project_doc_sync.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/project-doc-sync.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/project-doc-sync-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

MP="$WORKDIR/mergepath"
DOCS="$WORKDIR/docs"
APP="$WORKDIR/app"
mkdir -p "$MP/scripts" "$DOCS/projects/app/prds" "$APP/specs"
cp "$SCRIPT" "$MP/scripts/project-doc-sync.sh"
chmod +x "$MP/scripts/project-doc-sync.sh"

cat >"$DOCS/projects/app/prds/app.md" <<'EOF'
# App PRD

Product intent.
EOF
cat >"$APP/specs/feature.md" <<'EOF'
# Feature Spec

Implementation contract.
EOF
cat >"$APP/specs/old.md" <<'EOF'
# Old Spec

Will be deleted to verify orphan mirror detection.
EOF
git init -q "$DOCS"
(cd "$DOCS" && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m docs)
git init -q "$APP"
(cd "$APP" && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m app)

cat >"$MP/.mergepath-project-docs.yml" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$DOCS"
projects:
  - slug: app
    owner:
      name: app
      repo: example/app
      path_hint: "$APP"
    prds:
      - slug: app
        source: projects/app/prds/app.md
        mirror: docs/projects/app/prds/app.md
    specs:
      - source: specs/
        mirror: projects/app/specs/
EOF

set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "initial audit should report missing generated mirrors (rc=$rc): $out"
echo "$out" | grep -q "MISS  app prd:app" \
  || fail "initial audit should report missing app PRD mirror: $out"
echo "$out" | grep -q "MISS  app spec:feature" \
  || fail "initial audit should report missing app spec mirror: $out"

set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --projects typo --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown project filter should fail closed (rc=$rc): $out"
echo "$out" | grep -q "unknown project in --projects: typo" \
  || fail "unknown project filter should name the bad slug: $out"

MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >"$WORKDIR/project-doc-sync-materialize.out"

[ -f "$APP/docs/projects/app/prds/app.md" ] \
  || fail "materialize did not create repo-local PRD mirror"
[ -f "$DOCS/projects/app/specs/feature.md" ] \
  || fail "materialize did not create central spec mirror"
[ -f "$DOCS/projects/app/specs/old.md" ] \
  || fail "materialize did not create second central spec mirror"

grep -q "do_not_edit: true" "$APP/docs/projects/app/prds/app.md" \
  || fail "PRD mirror missing generated header"
grep -q "sync_direction: central-to-repo" "$APP/docs/projects/app/prds/app.md" \
  || fail "PRD mirror missing central-to-repo direction"
grep -q "sync_direction: repo-to-central" "$DOCS/projects/app/specs/feature.md" \
  || fail "spec mirror missing repo-to-central direction"
grep -q "source_repo: example/app" "$DOCS/projects/app/specs/feature.md" \
  || fail "spec mirror missing owning repo source metadata"

out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "audit should pass after materialize (rc=$rc): $out"

LINK_TARGET="$WORKDIR/symlink-target.txt"
printf 'do not clobber\n' >"$LINK_TARGET"
rm "$APP/docs/projects/app/prds/app.md"
ln -s "$LINK_TARGET" "$APP/docs/projects/app/prds/app.md"
MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ ! -L "$APP/docs/projects/app/prds/app.md" ] \
  || fail "materialize should replace symlinked PRD destination with a regular file"
[ "$(cat "$LINK_TARGET")" = "do not clobber" ] \
  || fail "materialize followed and clobbered symlink destination"

rm "$APP/specs/old.md"
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "audit should catch orphaned generated spec mirror (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app spec:old orphan" \
  || fail "orphan generated spec mirror should report drift: $out"

MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ ! -e "$DOCS/projects/app/specs/old.md" ] \
  || fail "materialize should remove orphaned generated spec mirror"

out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "audit should pass after orphan removal (rc=$rc): $out"

# Orphaned generated PRD mirror: a generated PRD file under the owner's
# prds/ dir that is no longer declared in the manifest (slug renamed or
# removed) must be reported as drift and removed on materialize, analogous
# to the spec orphan pass.
cp "$APP/docs/projects/app/prds/app.md" "$APP/docs/projects/app/prds/legacy.md"
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "audit should catch orphaned generated PRD mirror (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app prd:legacy orphan" \
  || fail "orphan generated PRD mirror should report drift: $out"

MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ ! -e "$APP/docs/projects/app/prds/legacy.md" ] \
  || fail "materialize should remove orphaned generated PRD mirror"
[ -f "$APP/docs/projects/app/prds/app.md" ] \
  || fail "materialize should keep the declared PRD mirror"

out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "audit should pass after PRD orphan removal (rc=$rc): $out"

# A hand-written (non-generated) file under the same prds/ dir must never be
# treated as an orphan mirror or removed: orphan handling is gated on this
# script's generated header.
printf '# Notes\n\nHand-written, not a generated mirror.\n' >"$APP/docs/projects/app/prds/NOTES.md"
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "hand-written PRD-dir file must not be flagged as orphan (rc=$rc): $out"
MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ -f "$APP/docs/projects/app/prds/NOTES.md" ] \
  || fail "materialize must not remove hand-written PRD-dir file"
rm "$APP/docs/projects/app/prds/NOTES.md"

CACHE_ROOT="$WORKDIR/cache"
SYMLINK_MP="$WORKDIR/mergepath-symlink-cache"
mkdir -p "$CACHE_ROOT" "$SYMLINK_MP/scripts"
cp "$SCRIPT" "$SYMLINK_MP/scripts/project-doc-sync.sh"
chmod +x "$SYMLINK_MP/scripts/project-doc-sync.sh"
ln -s "$DOCS" "$CACHE_ROOT/docs"
cat >"$SYMLINK_MP/.mergepath-project-docs.yml" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$WORKDIR/missing-docs"
projects:
  - slug: app
    owner:
      name: app
      repo: example/app
      path_hint: "$APP"
    prds:
      - slug: app
        source: projects/app/prds/app.md
        mirror: docs/projects/app/prds/app.md
EOF
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$SYMLINK_MP" MERGEPATH_PROJECT_DOCS_CACHE="$CACHE_ROOT" \
  "$SYMLINK_MP/scripts/project-doc-sync.sh" --audit 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "audit should refuse symlinked cache checkout (rc=$rc): $out"
echo "$out" | grep -qi "symbolic link" \
  || fail "symlinked cache refusal should name the symlink cause, not just exit 2: $out"

printf '\nlocal edit\n' >>"$DOCS/projects/app/specs/feature.md"
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "audit should catch manually edited generated spec mirror (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app spec:feature" \
  || fail "manual central spec edit should report drift: $out"

# ---------------------------------------------------------------------------
# Mapping/project lifecycle: orphan detection must fire even when the manifest
# mapping (or the whole project) that anchored a mirror is removed — not only
# when a single source file is deleted. The orphan pass is project-driven, so a
# project that stays in the manifest but loses a class mapping is still swept.
# ---------------------------------------------------------------------------
MANIFEST="$MP/.mergepath-project-docs.yml"
ORIG_MANIFEST="$WORKDIR/manifest.orig"
cp "$MANIFEST" "$ORIG_MANIFEST"
resync() { MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null; }
restore_manifest() { cp "$ORIG_MANIFEST" "$MANIFEST"; }

# Re-sync to a clean baseline (the manual-edit case above left feature.md drifted).
resync
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "lifecycle baseline should be clean (rc=$rc): $out"

# F1: a project's prds: mapping removed (project entry stays) → its PRD mirror
# in the owner repo is orphaned, flagged on audit and removed on materialize.
cat >"$MANIFEST" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$DOCS"
projects:
  - slug: app
    owner:
      name: app
      repo: example/app
      path_hint: "$APP"
    specs:
      - source: specs/
        mirror: projects/app/specs/
EOF
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "F1 audit should flag orphan PRD mirror after prds mapping removed (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app prd:app orphan" \
  || fail "F1: orphan PRD mirror not reported after prds mapping removed: $out"
MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ ! -e "$APP/docs/projects/app/prds/app.md" ] \
  || fail "F1 materialize should remove orphan PRD mirror after prds mapping removed"
restore_manifest; resync

# F2: a project's specs: mapping removed (project entry stays) → its central
# spec mirror is orphaned, flagged on audit and removed on materialize.
cat >"$MANIFEST" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$DOCS"
projects:
  - slug: app
    owner:
      name: app
      repo: example/app
      path_hint: "$APP"
    prds:
      - slug: app
        source: projects/app/prds/app.md
        mirror: docs/projects/app/prds/app.md
EOF
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "F2 audit should flag orphan spec mirror after specs mapping removed (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app spec:feature orphan" \
  || fail "F2: orphan spec mirror not reported after specs mapping removed: $out"
MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ ! -e "$DOCS/projects/app/specs/feature.md" ] \
  || fail "F2 materialize should remove orphan spec mirror after specs mapping removed"
restore_manifest; resync

# F4: the owner's entire specs/ source is emptied while the specs mapping stays
# → every central spec mirror is orphaned, flagged and removed.
mv "$APP/specs/feature.md" "$WORKDIR/feature.stash"
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "F4 audit should flag orphan spec mirror when source emptied (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app spec:feature orphan" \
  || fail "F4: orphan spec mirror not reported when source emptied: $out"
MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null
[ ! -e "$DOCS/projects/app/specs/feature.md" ] \
  || fail "F4 materialize should remove orphan spec mirror when source emptied"
mv "$WORKDIR/feature.stash" "$APP/specs/feature.md"; resync

# F3 (central side): a project removed from the manifest entirely → its
# generated central spec mirror is caught by the full-audit non-manifest sweep.
# (A --projects-scoped run must NOT touch it; owner-side PRD mirrors of a fully
# removed project are an accepted, documented limitation.)
cat >"$MANIFEST" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$DOCS"
projects: []
EOF
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "F3 full audit should flag central spec mirror of a removed project (rc=$rc): $out"
echo "$out" | grep -q "app spec:feature orphan (project not in manifest)" \
  || fail "F3: removed-project central spec mirror not reported: $out"
MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize >/dev/null
[ ! -e "$DOCS/projects/app/specs/feature.md" ] \
  || fail "F3 materialize should remove central spec mirror of a removed project"
restore_manifest; resync

# Read-only owner: central spec pruning must NOT require a writable owner
# checkout — the owner is only read to enumerate sources, and the removal
# target is the writable central repo. A clone-only owner (path_hint absent,
# resolved via the read-only cache) must still get its central spec orphans
# pruned on materialize.
RO_CACHE="$WORKDIR/ro-owner-cache"
mkdir -p "$RO_CACHE"
git clone -q "$APP" "$RO_CACHE/app"
cat >"$MANIFEST" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$DOCS"
projects:
  - slug: app
    owner:
      name: app
      repo: example/app
      path_hint: "$WORKDIR/no-such-owner-checkout"
    specs:
      - source: specs/
        mirror: projects/app/specs/
EOF
# A generated spec mirror with no matching source in the (cloned) owner.
cp "$DOCS/projects/app/specs/feature.md" "$DOCS/projects/app/specs/ghost.md"
MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_PROJECT_DOCS_CACHE="$RO_CACHE" \
  "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/dev/null 2>&1
[ ! -e "$DOCS/projects/app/specs/ghost.md" ] \
  || fail "materialize should prune a central spec orphan via a read-only (clone) owner"
restore_manifest; resync

# Path traversal: a manifest mirror/source with a `..` component must fail
# closed (exit 2) before any write, so it can never escape the mirror tree.
cat >"$MANIFEST" <<EOF
version: 1
central_repo:
  name: docs
  repo: example/docs
  path_hint: "$DOCS"
projects:
  - slug: app
    owner:
      name: app
      repo: example/app
      path_hint: "$APP"
    prds:
      - slug: app
        source: projects/app/prds/app.md
        mirror: ../../escape.md
EOF
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "traversal mirror path should fail closed (rc=$rc): $out"
echo "$out" | grep -q "traversal component" || fail "traversal path should be named in the error: $out"
[ ! -e "$WORKDIR/escape.md" ] && [ ! -e "$APP/escape.md" ] \
  || fail "traversal path must never be written"
restore_manifest; resync

echo "PASS: project-doc-sync"
