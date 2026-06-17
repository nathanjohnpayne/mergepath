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

MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --materialize --projects app >/tmp/project-doc-sync-materialize.out

[ -f "$APP/docs/projects/app/prds/app.md" ] \
  || fail "materialize did not create repo-local PRD mirror"
[ -f "$DOCS/projects/app/specs/feature.md" ] \
  || fail "materialize did not create central spec mirror"

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

printf '\nlocal edit\n' >>"$DOCS/projects/app/specs/feature.md"
set +e
out=$(MERGEPATH_ROOT_OVERRIDE="$MP" "$MP/scripts/project-doc-sync.sh" --audit --no-clone 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "audit should catch manually edited generated spec mirror (rc=$rc): $out"
echo "$out" | grep -q "DRIFT app spec:feature" \
  || fail "manual central spec edit should report drift: $out"

echo "PASS: project-doc-sync"
