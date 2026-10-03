#!/usr/bin/env bash
# Hermetic audit contract fixtures. Expected runtime ~15s, outer bound 180s.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/sync-to-downstream.sh"
for tool in git jq yq; do command -v "$tool" >/dev/null || { echo "SKIP: $tool unavailable"; exit 0; }; done
yq --version | grep -q mikefarah/yq || { echo 'SKIP: mikefarah/yq unavailable'; exit 0; }
REAL_FIND=$(command -v find)
REAL_MKTEMP=$(command -v mktemp)
REAL_CAT=$(command -v cat)
REAL_RM=$(command -v rm)
REAL_YQ=$(command -v yq)
REAL_JQ=$(command -v jq)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sync-audit-json.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
MP="$WORK/hub" SIB="$WORK/siblings" CACHE="$WORK/cache"
mkdir -p "$MP/scripts/sync" "$MP/scripts/lib" "$MP/kit" "$SIB" "$WORK/bin"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$MP/scripts/sync/"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$ROOT/scripts/lib/template-substitution.sh" "$MP/scripts/lib/"
# Keep fixture git identities/config outside the real checkout/global config.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
commit_fixture() { git -C "$1" add -A; git -C "$1" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm "$2"; }
printf 'base\n' > "$MP/canonical.txt"
printf 'old\n' > "$MP/hub-changed.txt"
printf 'kit-base\n' > "$MP/kit/one"
printf 'hello {{name}}\n' > "$MP/template.txt"
cat > "$MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: clean, repo: fixture/clean, visibility: public, facts: {name: clean}}
  - {name: drift, repo: fixture/drift, visibility: private, facts: {name: drift}}
  - {name: ahead, repo: fixture/ahead, visibility: public, facts: {name: ahead}}
  - {name: overlay, repo: fixture/overlay, visibility: public, facts: {name: overlay}}
  - {name: failed, repo: fixture/failed, visibility: private, facts: {name: failed}}
paths:
  - {path: canonical.txt, type: canonical, consumers: all}
  - {path: hub-changed.txt, type: canonical, consumers: all}
  - {path: kit/, type: kit, consumers: all}
  - {path: template.txt, source: template.txt, dest: rendered.txt, type: templated, consumers: all}
YAML
git init -qb main "$MP"
commit_fixture "$MP" 'hub baseline'
SOURCE=$(git -C "$MP" rev-parse HEAD)
for name in clean drift ahead overlay; do
  mkdir -p "$SIB/$name/kit"
  cp "$MP/canonical.txt" "$MP/hub-changed.txt" "$SIB/$name/"
  cp "$MP/kit/one" "$SIB/$name/kit/"
  printf 'hello %s\n' "$name" > "$SIB/$name/rendered.txt"
  git init -qb main "$SIB/$name"
  commit_fixture "$SIB/$name" "$(printf 'bulk sync to mergepath@%s\n\nSource: https://github.com/nathanjohnpayne/mergepath/commit/%s' "${SOURCE:0:7}" "$SOURCE")"
done
printf 'new\n' > "$MP/hub-changed.txt"
commit_fixture "$MP" 'hub changed one path'
HUB_SHA=$(git -C "$MP" rev-parse HEAD)
cp "$MP/hub-changed.txt" "$SIB/clean/"
printf 'allowed extra\n' > "$SIB/clean/kit/extra"
commit_fixture "$SIB/clean" 'consumer catches up'
printf 'consumer change\n' > "$SIB/ahead/canonical.txt"
printf 'consumer kit change\n' > "$SIB/ahead/kit/one"
commit_fixture "$SIB/ahead" 'consumer changes after shared baseline'
cp "$MP/hub-changed.txt" "$SIB/overlay/"
printf 'intentional\n' > "$SIB/overlay/canonical.txt"
printf 'custom template\n' > "$SIB/overlay/rendered.txt"
cat > "$SIB/overlay/.sync-overrides.yml" <<'YAML'
skip_paths:
  - {path: canonical.txt, reason: 'owner "overlay" choice'}
  - {path: rendered.txt, reason: 'rendered overlay'}
  - {path: kit/, reason: 'matching kit does not diverge'}
YAML
commit_fixture "$SIB/overlay" 'intentional overlays'
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2" = 'api graphql' ] || { echo 'unexpected gh invocation' >&2; exit 91; }
printf '%s\n' "$*" >> "$AUDIT_CALLS"
case "${AUDIT_GH_MODE:-clean}" in
  denied) echo 'private-provider-message-must-not-leak' >&2; exit 1 ;;
  malformed) echo '{broken'; exit 0 ;;
  errors) echo '{"errors":[{"message":"denied"}],"data":{"repository":null}}'; exit 0 ;;
  missing) echo '{"data":{"repository":null}}'; exit 0 ;;
  invalid_node) echo '{"data":{"repository":{"pullRequests":{"nodes":[{"number":1,"headRefName":"mergepath-sync/x","state":"OPEN","mergeStateStatus":"","isDraft":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'; exit 0 ;;
  missing_cursor) echo '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}'; exit 0 ;;
  partial)
    if [[ "$*" == *'cursor=next'* ]]; then exit 1; fi ;;
esac
if [[ "${AUDIT_GH_MODE:-clean}" == paginate || "${AUDIT_GH_MODE:-clean}" == partial || "${AUDIT_GH_MODE:-clean}" == stuck ]]; then
  if [[ "$*" != *'cursor=next'* ]]; then
    echo '{"data":{"repository":{"pullRequests":{"nodes":[{"number":1,"headRefName":"ordinary/feature","state":"OPEN","mergeStateStatus":"CLEAN","isDraft":false}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}'
  else
    echo '{"data":{"repository":{"pullRequests":{"nodes":[{"number":88,"headRefName":"mergepath-sync/sync-all-abc","state":"OPEN","mergeStateStatus":"BEHIND","isDraft":false},{"number":89,"headRefName":"mergepath-sync/def","state":"OPEN","mergeStateStatus":"UNKNOWN","isDraft":true}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}' | if [ "${AUDIT_GH_MODE:-clean}" = stuck ]; then cat; else sed 's/"hasNextPage":true/"hasNextPage":false/'; fi
  fi
else
  echo '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
fi
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" AUDIT_CALLS="$WORK/calls" MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIB" MERGEPATH_SYNC_CACHE="$CACHE"
# Avoid consulting an operator preflight cache: synthetic hub has no helper.
unset GH_TOKEN GITHUB_TOKEN OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
fail() { echo "FAIL: $*" >&2; cat "$WORK/out" "$WORK/err" >&2; exit 1; }
run() {
  local expected=$1; shift
  local rc=0
  "$SCRIPT" "$@" > "$WORK/out" 2> "$WORK/err" || rc=$?
  [ "$rc" = "$expected" ] || fail "expected exit $expected, got $rc: $*"
}
assert_json() { jq -es "$1" "$WORK/out" >/dev/null || fail "$1"; }
# Exercise the propagated wrapper itself, replacing only its suite boundaries.
# Old engine/test residue must not introduce a JSON dependency without the hub
# manifest. Preserve the existing legacy/project-doc dispatch and error exits.
WRAPPER_FIXTURE="$WORK/wrapper"
export WRAPPER_TRACE="$WORK/wrapper-calls" WRAPPER_LEGACY_RC=0
wrapper_fixture() { # manifest engine legacy json
  rm -rf "$WRAPPER_FIXTURE"
  mkdir -p "$WRAPPER_FIXTURE/scripts/ci" "$WRAPPER_FIXTURE/tests"
  cp "$ROOT/scripts/ci/check_sync_to_downstream" "$WRAPPER_FIXTURE/scripts/ci/"
  [ "$1" = no ] || touch "$WRAPPER_FIXTURE/.mergepath-sync.yml"
  [ "$2" = no ] || touch "$WRAPPER_FIXTURE/scripts/sync-to-downstream.sh"
  if [ "$3" = yes ]; then
    cat > "$WRAPPER_FIXTURE/tests/test_sync_to_downstream.sh" <<'SH'
printf 'legacy\n' >> "$WRAPPER_TRACE"
exit "${WRAPPER_LEGACY_RC:-0}"
SH
  fi
  if [ "$4" = yes ]; then
    cat > "$WRAPPER_FIXTURE/tests/test_sync_audit_json.sh" <<'SH'
printf 'json\n' >> "$WRAPPER_TRACE"
SH
  fi
  cat > "$WRAPPER_FIXTURE/tests/test_project_doc_sync.sh" <<'SH'
printf 'project-doc\n' >> "$WRAPPER_TRACE"
SH
}
check_wrapper() { # expected exit, exact ordered suite calls
  local rc=0
  : > "$WRAPPER_TRACE"
  bash "$WRAPPER_FIXTURE/scripts/ci/check_sync_to_downstream" > "$WORK/out" 2> "$WORK/err" || rc=$?
  [ "$rc" = "$1" ] || fail "wrapper expected exit $1, got $rc"
  [ "$(cat "$WRAPPER_TRACE")" = "$2" ] || fail "wrapper dispatched unexpected suites: $(cat "$WRAPPER_TRACE")"
}
wrapper_fixture no no no no
check_wrapper 0 ''
grep -q '^check_sync_to_downstream: SKIP (consumer checkout:' "$WORK/out" || fail 'legacy consumer skip changed'
wrapper_fixture no yes yes no
check_wrapper 0 $'legacy\nproject-doc'
wrapper_fixture no yes yes yes
check_wrapper 0 $'legacy\nproject-doc'
# The existing integrity gate still catches hub manifest deletion; the new
# wrapper guard does not turn that malformed checkout into a passing hub.
manifest_rc=0
MERGEPATH_REPO_ROOT="$WRAPPER_FIXTURE" MERGEPATH_MANIFEST_PATH="$WRAPPER_FIXTURE/.mergepath-sync.yml" \
  bash "$ROOT/scripts/ci/check_sync_manifest" > "$WORK/out" 2> "$WORK/err" || manifest_rc=$?
[ "$manifest_rc" = 1 ] || fail 'missing hub manifest no longer fails its existing gate'
wrapper_fixture yes yes yes no
check_wrapper 1 legacy
grep -q 'missing .*tests/test_sync_audit_json.sh' "$WORK/err" || fail 'hub missing JSON suite did not fail explicitly'
wrapper_fixture yes yes yes yes
check_wrapper 0 $'legacy\njson\nproject-doc'
WRAPPER_LEGACY_RC=7
check_wrapper 7 legacy
WRAPPER_LEGACY_RC=0
wrapper_fixture yes yes no yes
check_wrapper 1 ''
grep -q 'missing .*tests/test_sync_to_downstream.sh' "$WORK/err" || fail 'hub missing legacy suite no longer fails'
unset WRAPPER_TRACE WRAPPER_LEGACY_RC
# Golden legacy output: complete fixed fixture; independent of checkout history.
# Byte-compare stdout and stderr, not a reconstructed JSON rendering.
run 3 --audit --use-local-tree --no-clone
{
  for name in clean drift ahead overlay; do
    printf '%s (fixture/%s)\n' "$name" "$name"
    printf '  baseline: main@%s (LOCAL SIBLING TREE at %s, used as-is — never auto-fetched)\n' \
      "$(git -C "$SIB/$name" rev-parse --short HEAD)" "$SIB/$name"
    if [ "$name" = overlay ]; then
      printf '  ↷ %-50s skipped per .sync-overrides.yml: %s\n' canonical.txt 'owner "overlay" choice'
    elif [ "$name" = ahead ]; then
      printf '  ✗ %-50s drift: 4 diff line(s)\n' canonical.txt
    else
      printf '  ✓ %-50s in sync\n' canonical.txt
    fi
    if [ "$name" = drift ] || [ "$name" = ahead ]; then
      printf '  ✗ %-50s drift: 4 diff line(s)\n' hub-changed.txt
    else
      printf '  ✓ %-50s in sync\n' hub-changed.txt
    fi
    if [ "$name" = ahead ]; then
      printf '  ✗ %-50s drift: 1 file(s) drifted, 0 file(s) missing\n' kit/
    elif [ "$name" = overlay ]; then
      printf '  ↷ %-50s skipped per .sync-overrides.yml: matching kit does not diverge\n' kit/
    else
      printf '  ✓ %-50s in sync\n' kit/
    fi
    if [ "$name" = overlay ]; then
      printf '  ↷ %-50s skipped per .sync-overrides.yml: rendered overlay\n' rendered.txt
    else
      printf '  ✓ %-50s in sync\n' rendered.txt
    fi
    printf '\n'
  done
  printf 'failed (fixture/failed)\n  ! no local worktree for failed (set MERGEPATH_SIBLINGS_DIR or drop --no-clone)\n'
} > "$WORK/golden-text"
cmp "$WORK/golden-text" "$WORK/out" || fail 'legacy golden stdout differs'
[ ! -s "$WORK/err" ] || fail 'legacy golden stderr differs'
run 3 --audit --json --use-local-tree --no-clone
assert_json 'length == 5 and ([.[].status] == ["in-sync","drift","ahead","override-only","fetch-error"])'
assert_json '.[0].visibility == "public" and .[1].visibility == "private" and .[0].paths == [] and .[0].open_sync_prs == []'
assert_json '.[2].paths | any(.path == "canonical.txt" and .direction == "consumer ahead of hub" and (.provenance.source_sha | length == 40))'
assert_json '.[2].paths | any(.path == "kit/one" and .class == "kit" and .direction == "consumer ahead of hub")'
assert_json '.[2].paths | any(.path == "hub-changed.txt" and .direction == "hub ahead")'
assert_json '.[3].paths | length == 2 and all(.[]; .direction == "covered by .sync-overrides.yml")'
assert_json '.[4].baseline == null and .[4].open_sync_prs == null and .[4].error.reason == "no local worktree"'
run 1 --json --audit --use-local-tree --no-clone --repos fixture/ahead --paths canonical.txt
assert_json 'length == 1 and .[0].status == "ahead" and (. [0].paths | length == 1)'
run 0 --audit --json --use-local-tree --no-clone --repos clean
assert_json '.[0].baseline_info.sha | length == 40'
run 0 --audit --json --use-local-tree --no-clone --repos overlay
run 0 --audit --json --use-local-tree --no-clone --repos overlay --paths kit/
assert_json '.[0].status == "in-sync" and .[0].paths == []'
run 1 --audit --json --use-local-tree --no-clone --repos drift
# Dirty consumer, forged sync payload, missing history and both-changed proof refusal.
printf 'uncommitted\n' > "$SIB/ahead/canonical.txt"
run 1 --audit --json --use-local-tree --no-clone --repos ahead --paths canonical.txt
assert_json '.[0].status == "drift" and .[0].baseline_info.dirty and .[0].paths[0].direction == "unverified divergence"'
git -C "$SIB/ahead" restore canonical.txt
# Relevant mode mismatch remains unverified even with core.filemode=false.
chmod +x "$SIB/ahead/canonical.txt"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.filemode GIT_CONFIG_VALUE_0=false \
  run 1 --audit --json --use-local-tree --no-clone --repos ahead --paths canonical.txt
assert_json '.[0].status == "drift" and .[0].paths[0].provenance == null'
chmod -x "$SIB/ahead/canonical.txt"
printf 'hub also changed\n' > "$MP/canonical.txt"
commit_fixture "$MP" 'hub path also changed'
run 1 --audit --json --use-local-tree --no-clone --repos ahead --paths canonical.txt
assert_json '.[0].status == "drift" and .[0].paths[0].provenance == null'
git -C "$MP" checkout -q "$HUB_SHA"
printf 'forged baseline\n' > "$SIB/clean/canonical.txt"
commit_fixture "$SIB/clean" "$(printf 'claimed sync\n\nSource: https://github.com/nathanjohnpayne/mergepath/commit/%s' "$SOURCE")"
run 1 --audit --json --use-local-tree --no-clone --repos clean --paths canonical.txt
# A false latest anchor must not itself prove ahead; older TRUE baseline may.
assert_json '.[0].paths[0].provenance.sync_sha != .[0].baseline_info.sha'
git -C "$SIB/clean" restore --source=HEAD~1 -- canonical.txt
commit_fixture "$SIB/clean" 'restore canonical'
git clone -q --depth=1 "file://$SIB/ahead" "$WORK/shallow"
mv "$SIB/ahead" "$SIB/ahead-original"
mv "$WORK/shallow" "$SIB/ahead"
run 1 --audit --json --use-local-tree --no-clone --repos ahead --paths canonical.txt
assert_json '.[0].status == "drift" and .[0].paths[0].direction == "unverified divergence"'
mv "$SIB/ahead" "$WORK/shallow-done"
mv "$SIB/ahead-original" "$SIB/ahead"
# Missing canonical path and templated rendering remain explicit differences.
rm "$SIB/drift/canonical.txt"
printf 'wrong rendered\n' > "$SIB/drift/rendered.txt"
run 1 --audit --json --use-local-tree --no-clone --repos drift
assert_json '.[0].paths | any(.path == "canonical.txt" and .comparison == "missing" and .direction == "hub ahead") and any(.path == "rendered.txt" and .class == "templated" and .direction == "re-render differs")'
# Overridden differences plus uncovered drift => drift; matching skips => clean.
printf 'wrong kit\n' > "$SIB/overlay/kit/one"
# Remove kit skip from this fixture only.
yq -i '.skip_paths |= map(select(.path != "kit/"))' "$SIB/overlay/.sync-overrides.yml"
run 1 --audit --json --use-local-tree --no-clone --repos overlay
assert_json '.[0].status == "drift" and (. [0].paths | length == 3)'
run 0 --audit --json --use-local-tree --no-clone --repos overlay --paths hub-changed.txt
# Cursor pagination and source failures never become a false empty PR list.
export AUDIT_GH_MODE=paginate
: > "$AUDIT_CALLS"
run 0 --audit --json --use-local-tree --no-clone --repos clean
assert_json '.[0].open_sync_prs | length == 2 and .[0].number == 88 and .[0].state == "BEHIND" and .[1].state == "UNKNOWN" and .[1].draft'
[ "$(wc -l < "$AUDIT_CALLS" | tr -d ' ')" = 2 ] || fail 'pagination request count'
for mode in denied malformed errors missing invalid_node missing_cursor partial stuck; do
  export AUDIT_GH_MODE=$mode
  run 3 --audit --json --use-local-tree --no-clone --repos clean
  assert_json '.[0].status == "fetch-error" and .[0].open_sync_prs == null and .[0].error.source == "open_sync_prs"'
  ! grep -q private-provider-message "$WORK/out" "$WORK/err" || fail 'provider stderr leaked'
done
export AUDIT_GH_MODE=clean
# Invalid flag/filter combinations keep exit 2 and never invoke providers.
: > "$AUDIT_CALLS"
run 2 --sync-all --json --dry-run
run 2 --audit --json --repos typo
run 2 --audit --json --repos clean --paths unmapped
[ ! -s "$AUDIT_CALLS" ] || fail 'provider called after usage error'
# Empty kit and failed enumeration must not become false clean records.
mkdir -p "$MP/empty-kit"
yq -i '.paths += [{"path":"empty-kit/", "type":"kit", "consumers":"all"}]' "$MP/.mergepath-sync.yml"
run 1 --audit --json --use-local-tree --no-clone --repos clean --paths empty-kit/
assert_json '.[0].status == "drift" and .[0].paths[0].comparison == "missing" and .[0].paths[0].class == "kit"'
mkdir -p "$SIB/clean/empty-kit"
run 0 --audit --json --use-local-tree --no-clone --repos clean --paths empty-kit/
assert_json '.[0].status == "in-sync"'
cat > "$WORK/bin/find" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$WORK/bin/find"
run 2 --audit --json --use-local-tree --no-clone --repos clean --paths kit/
[ ! -s "$WORK/out" ] || fail 'failed enumeration emitted a clean record'
# A later fatal consumer cannot publish an earlier successful record prefix.
# The real CLI is invoked with two selected consumers in manifest order.
export REAL_FIND AUDIT_FIND_CALLS="$WORK/find-calls"
: > "$AUDIT_FIND_CALLS"
cat > "$WORK/bin/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'find\n' >> "$AUDIT_FIND_CALLS"
[ "$(wc -l < "$AUDIT_FIND_CALLS" | tr -d ' ')" -lt 2 ] || exit 1
exec "$REAL_FIND" "$@"
SH
chmod +x "$WORK/bin/find"
: > "$AUDIT_CALLS"
run 2 --audit --json --use-local-tree --no-clone --repos clean,drift --paths kit/
[ "$(wc -l < "$AUDIT_FIND_CALLS" | tr -d ' ')" = 2 ] || fail 'later enumeration failure not exercised'
[ "$(wc -l < "$AUDIT_CALLS" | tr -d ' ')" = 1 ] || fail 'first consumer did not complete before fatal second consumer'
[ ! -s "$WORK/out" ] || fail 'later fatal consumer published incomplete NDJSON prefix'
rm "$WORK/bin/find"
# Isolate JSON-owned temp files so success and every abort prove cleanup.
AUDIT_TMP="$WORK/audit-tmp"
mkdir -p "$AUDIT_TMP"
export REAL_MKTEMP REAL_CAT REAL_RM REAL_YQ REAL_JQ
export AUDIT_FAULT_LOG="$WORK/fault-log"
cat > "$WORK/bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *audit-json-output.*)
    case "${AUDIT_FAULT:-}" in
      allocate) exit 7 ;;
      write)
        path=$("$REAL_MKTEMP" "$@")
        "$REAL_RM" -f "$path"
        mkdir "$path"
        printf '%s\n' "$path"
        exit 0 ;;
    esac ;;
  *audit-json-kit.*)
    if [ "${AUDIT_FAULT:-}" = kit_allocate ]; then
      printf 'kit\n' >> "$AUDIT_FAULT_LOG"
      [ "$(wc -l < "$AUDIT_FAULT_LOG" | tr -d ' ')" -lt 2 ] || exit 7
    fi ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
cat > "$WORK/bin/cat" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${AUDIT_FAULT:-}" = read ] && [[ "$*" == *audit-json-output.* ]]; then exit 8; fi
exec "$REAL_CAT" "$@"
SH
cat > "$WORK/bin/rm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${AUDIT_FAULT:-}" = cleanup ] && [[ "$*" == *audit-json-output.* ]] && [ ! -s "$AUDIT_FAULT_LOG" ]; then
  printf 'cleanup\n' >> "$AUDIT_FAULT_LOG"
  exit 9
fi
exec "$REAL_RM" "$@"
SH
cat > "$WORK/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${AUDIT_FAULT:-}" = visibility ] && [ "${AUDIT_CONSUMER:-}" = drift ]; then exit 7; fi
exec "$REAL_YQ" "$@"
SH
cat > "$WORK/bin/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${AUDIT_FAULT:-}" = serialize ] && [[ "$*" == '-cn --arg name drift '* ]]; then
  printf '{"incomplete":'
  exit 4
fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$WORK/bin/mktemp" "$WORK/bin/cat" "$WORK/bin/rm" "$WORK/bin/yq" "$WORK/bin/jq"
for fault in allocate write kit_allocate visibility serialize read cleanup; do
  export AUDIT_FAULT=$fault
  : > "$AUDIT_FAULT_LOG"
  : > "$AUDIT_CALLS"
  TMPDIR="$AUDIT_TMP" run 2 --audit --json --use-local-tree --no-clone --repos clean,drift --paths kit/
  [ ! -s "$WORK/out" ] || fail "$fault published incomplete audit output"
  case "$fault" in
    allocate|write) [ ! -s "$AUDIT_CALLS" ] || fail "$fault called provider before buffer was usable" ;;
    kit_allocate|visibility) [ "$(wc -l < "$AUDIT_CALLS" | tr -d ' ')" = 1 ] || fail "$fault did not abort after first completed consumer" ;;
    serialize|read|cleanup) [ "$(wc -l < "$AUDIT_CALLS" | tr -d ' ')" = 2 ] || fail "$fault did not exercise final serialization/publication" ;;
  esac
  if [ "$fault" = write ]; then
    # The returned directory deliberately makes opening stdout's buffer fail
    # even under root. The EXIT trap attempted unlink; fixture owns its rmdir.
    grep -Eq 'Is a directory|is a directory' "$WORK/err" || fail 'buffer open/write failure was not exercised'
    rmdir "$AUDIT_TMP"/audit-json-output.*
  fi
  [ -z "$("$REAL_FIND" "$AUDIT_TMP" -mindepth 1 -print)" ] || fail "$fault leaked JSON temporary state"
done
unset AUDIT_FAULT
rm "$WORK/bin/mktemp" "$WORK/bin/cat" "$WORK/bin/rm" "$WORK/bin/yq" "$WORK/bin/jq"
for expected_and_repos in '0 clean,drift' '1 clean,ahead' '3 clean,failed'; do
  read -r expected repos <<< "$expected_and_repos"
  TMPDIR="$AUDIT_TMP" run "$expected" --audit --json --use-local-tree --no-clone --repos "$repos" --paths kit/
  assert_json 'length == 2 and .[0].name == "clean"'
  [ -z "$("$REAL_FIND" "$AUDIT_TMP" -mindepth 1 -print)" ] || fail 'completed audit leaked JSON temporary state'
done
yq -i '.paths |= map(select(.path != "empty-kit/"))' "$MP/.mergepath-sync.yml"
# Default cache baseline remains live, ignores sibling edits, follows rename.
mkdir -p "$CACHE"
git clone -q --depth=1 "file://$SIB/clean" "$CACHE/clean"
printf 'stale sibling\n' > "$SIB/clean/canonical.txt"
run 0 --audit --json --repos clean
assert_json '.[0].status == "in-sync" and .[0].baseline_info.kind == "cache-clone" and .[0].baseline_info.refreshed and .[0].baseline_info.ref == "main"'
run 1 --audit --json --use-local-tree --no-clone --repos clean
assert_json '.[0].baseline_info.kind == "local-tree" and .[0].baseline_info.dirty'
git -C "$SIB/clean" branch -m main trunk
printf 'renamed default difference\n' > "$SIB/clean/canonical.txt"
commit_fixture "$SIB/clean" 'changed on renamed default'
RENAMED_SHA=$(git -C "$SIB/clean" rev-parse HEAD)
run 1 --audit --json --repos clean
assert_json '.[0].baseline_info.ref == "trunk"'
[ "$(jq -r .baseline "$WORK/out")" = "trunk@$RENAMED_SHA" ] || fail 'exact renamed baseline'
run 1 --audit --json --repos clean --no-refresh
assert_json '.[0].baseline_info.refreshed == false'
# Refresh failure cannot fall back to last cached bytes.
git -C "$CACHE/clean" remote set-url origin "$WORK/absent-origin"
run 3 --audit --json --repos clean
assert_json '.[0].baseline == null and .[0].error.reason == "consumer default-branch refresh failed"'
echo 'PASS: sync audit JSON states, provenance, pagination, failures, filters, live baseline, and text parity'
