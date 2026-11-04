#!/usr/bin/env bash
# tests/test_pr_assets_upload.sh
#
# Hermetic suite for scripts/pr-assets-upload.sh (mergepath#2938).
#
# Stand-ins:
#   - a local bare repository for nathanjohnpayne/pr-assets, reached through
#     the script's file://-only test seam (PR_ASSETS_TEST_REMOTE_URL);
#   - a PATH-shimmed `gh` that serves JSON fixtures per REST endpoint, applies
#     --jq with the real jq, answers commits/<sha> from the bare repository,
#     and logs every call;
#   - a PATH-shimmed `git` that passes every call through to the real git,
#     logs argv, and can land a competing commit on the bare repository just
#     before a push (the concurrent-upload race);
#   - a fake gpg program, to prove the commit honours the caller's signing
#     configuration.
#
# No network, no real credential. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${PR_ASSETS_UPLOAD_UNDER_TEST:-$ROOT/scripts/pr-assets-upload.sh}"
[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test_pr_assets_upload: jq is required" >&2; exit 1; }

REAL_GIT="$(command -v git)"
T="$(mktemp -d "${TMPDIR:-/tmp}/pr-assets-upload-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

TOKEN="github_pat_TESTONLY0000000000000000000000000000000000000000000000000000000000000000000000"

# ── Hermetic git identity ─────────────────────────────────────────────
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/mock"
cat > "$T/gitconfig" <<'EOF'
[user]
	name = Test Author
	email = author@example.invalid
[commit]
	gpgsign = false
[init]
	defaultBranch = main
EOF
export HOME="$T/home"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_TOKEN GITHUB_TOKEN GH_HOST \
  OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_PR_ASSETS_PAT \
  PR_ASSETS_TEST_REMOTE_URL GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

# ── Mock gh ───────────────────────────────────────────────────────────
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fixture-backed gh. Fixture for endpoint E: $MOCK_DIR/<E with / as __>.json.
set -u
printf '%s\n' "$*" >> "$MOCK_DIR/gh.log"
[ "${1:-}" = "api" ] || { echo "mock gh: unexpected command: $*" >&2; exit 90; }
shift
endpoint="" jq_expr="" method="GET"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname) shift 2 ;;
    --method|-X) method="$2"; shift 2 ;;
    --jq|-q) jq_expr="$2"; shift 2 ;;
    -*) echo "mock gh: unexpected flag $1" >&2; exit 91 ;;
    *) endpoint="$1"; shift ;;
  esac
done
[ "$method" = "GET" ] || { echo "mock gh: non-GET $method $endpoint" >&2; exit 92; }
case "$endpoint" in
  repos/nathanjohnpayne/pr-assets/commits/*)
    sha="${endpoint##*/}"
    if [ "${MOCK_FAIL_CONFIRM:-0}" != "1" ] \
       && "$REAL_GIT" --git-dir="$MOCK_BARE" cat-file -e "$sha^{commit}" 2>/dev/null; then
      json="{\"sha\":\"$sha\"}"
    else
      echo "gh: Not Found (HTTP 404)" >&2; exit 1
    fi
    ;;
  *)
    f="$MOCK_DIR/$(printf '%s' "$endpoint" | sed 's#/#__#g').json"
    [ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    json="$(cat "$f")"
    ;;
esac
if [ -n "$jq_expr" ]; then
  printf '%s' "$json" | jq -r "$jq_expr"
else
  printf '%s\n' "$json"
fi
EOF
chmod +x "$T/bin/gh"

# ── git shim: log argv, optionally race a push ────────────────────────
cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$MOCK_DIR/git.argv.log"
is_push=0
for a in "$@"; do [ "$a" = "push" ] && is_push=1 && break; done
[ "$is_push" = 1 ] && printf '%s\n' "$HOME" >> "$MOCK_DIR/push.home"
if [ "$is_push" = 1 ] && [ -n "${MOCK_RACE:-}" ]; then
  n=$(( $(cat "$MOCK_DIR/race.count" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$MOCK_DIR/race.count"
  if [ "$MOCK_RACE" = "always" ] || [ "$n" -eq 1 ]; then
    rpath="${MOCK_RACE_PATH:-other/1/race-$n.png}"
    (
      export GIT_DIR="$MOCK_BARE" GIT_INDEX_FILE="$MOCK_DIR/race.index"
      export GIT_AUTHOR_NAME=Race GIT_AUTHOR_EMAIL=race@example.invalid
      export GIT_COMMITTER_NAME=Race GIT_COMMITTER_EMAIL=race@example.invalid
      blob=$(printf '\211PNG\r\n\032\nrace-%s' "$n" | "$REAL_GIT" hash-object -w --stdin)
      "$REAL_GIT" read-tree refs/heads/main
      "$REAL_GIT" update-index --add --cacheinfo "100644,$blob,$rpath"
      tree=$("$REAL_GIT" write-tree)
      c=$(printf 'race %s\n' "$n" | "$REAL_GIT" commit-tree "$tree" -p refs/heads/main)
      "$REAL_GIT" update-ref refs/heads/main "$c"
      rm -f "$GIT_INDEX_FILE"
    )
  fi
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$T/bin/git"

export REAL_GIT
export MOCK_DIR="$T/mock"
export PATH="$T/bin:$PATH"

# ── Image fixtures ────────────────────────────────────────────────────
mkdir -p "$T/img"
png() { printf '\211PNG\r\n\032\n%s' "$2" > "$T/img/$1"; }
png desktop.png "desktop-bytes"
png phone.png "phone-bytes"
png other.png "other-bytes"
printf '\377\330\377\340jpeg-bytes' > "$T/img/shot.jpg"
printf 'GIF89a-gif-bytes' > "$T/img/anim.gif"
printf 'RIFF\044\000\000\000WEBPVP8 webp-bytes' > "$T/img/pic.webp"
printf 'not an image at all' > "$T/img/fake.png"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$T/img/logo.svg"
printf 'hello' > "$T/img/notes.txt"
cp "$T/img/desktop.png" "$T/img/my file.png"
cp "$T/img/desktop.png" "$T/img/.hidden.png"
cp "$T/img/desktop.png" "$T/img/UPPER.PNG"
mkdir -p "$T/img/dup"
png dup/desktop.png "different-desktop"

# ── Fixtures and store reset ──────────────────────────────────────────
write_fixtures() { # defaults: everything valid
  rm -f "$MOCK_DIR"/*.json
  printf '%s' '{"login":"nathanjohnpayne"}' > "$MOCK_DIR/user.json"
  printf '%s' '{"full_name":"nathanjohnpayne/pr-assets","visibility":"public","private":false,"default_branch":"main","permissions":{"push":true}}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__pr-assets.json"
  printf '%s' '{"full_name":"nathanjohnpayne/mergepath","name":"mergepath","owner":{"login":"nathanjohnpayne"},"visibility":"public","private":false}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__mergepath.json"
  printf '%s' '{"number":42}' > "$MOCK_DIR/repos__nathanjohnpayne__mergepath__issues__42.json"
  printf '%s' '{"full_name":"nathanjohnpayne/secret-thing","name":"secret-thing","owner":{"login":"nathanjohnpayne"},"visibility":"private","private":true}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__secret-thing.json"
  printf '%s' '{"full_name":"nathanjohnpayne/corp","name":"corp","owner":{"login":"nathanjohnpayne"},"visibility":"internal","private":false}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__corp.json"
  # The PR exists in both, so only the visibility check can refuse them.
  printf '%s' '{"number":42}' > "$MOCK_DIR/repos__nathanjohnpayne__secret-thing__issues__42.json"
  printf '%s' '{"number":42}' > "$MOCK_DIR/repos__nathanjohnpayne__corp__issues__42.json"
  printf '%s' '{"full_name":"someone-else/mergepath","name":"mergepath","owner":{"login":"someone-else"},"visibility":"public","private":false}' \
    > "$MOCK_DIR/repos__someone-else__mergepath.json"
  printf '%s' '{"number":42}' > "$MOCK_DIR/repos__someone-else__mergepath__issues__42.json"
}

BARE="$T/store.git"
export MOCK_BARE="$BARE"
reset_store() {
  rm -rf "$BARE" "$T/seed" "$MOCK_DIR"/*.log "$MOCK_DIR/race.count"
  "$REAL_GIT" init -q --bare "$BARE"
  "$REAL_GIT" -C "$BARE" config uploadpack.allowFilter true
  "$REAL_GIT" init -q "$T/seed"
  mkdir -p "$T/seed/mergepath/7"
  printf 'store readme\n' > "$T/seed/README.md"
  printf '\211PNG\r\n\032\nexisting' > "$T/seed/mergepath/7/existing.png"
  "$REAL_GIT" -C "$T/seed" add -A
  "$REAL_GIT" -C "$T/seed" commit -qm seed
  "$REAL_GIT" -C "$T/seed" push -q "$BARE" HEAD:refs/heads/main
  write_fixtures
  unset MOCK_RACE MOCK_RACE_PATH MOCK_FAIL_CONFIRM || true
}

main_sha() { "$REAL_GIT" --git-dir="$BARE" rev-parse refs/heads/main; }

# run [args...]: invoke the script with the standard test env; sets RC, OUT, ERR.
run() {
  set +e
  ( cd "${RUN_CWD:-$T}" && \
    OP_PREFLIGHT_PR_ASSETS_PAT="${RUN_TOKEN-$TOKEN}" \
    PR_ASSETS_TEST_REMOTE_URL="${RUN_REMOTE-file://$BARE}" \
    TMPDIR="$T/tmp" \
    "$SCRIPT" "$@" >"$T/out" 2>"$T/err" )
  RC=$?
  set -e
  OUT="$(cat "$T/out")"
  ERR="$(cat "$T/err")"
}

expect_rc() { # <want> <label>
  if [ "$RC" -eq "$1" ]; then return 0; fi
  fail "$2: expected exit $1, got $RC; stderr: $ERR"
  return 1
}

expect_store_unchanged() { # <sha before> <label>
  if [ "$(main_sha)" = "$1" ]; then return 0; fi
  fail "$2: the store moved but should not have"
  return 1
}

# ══════════════════════════════════════════════════════════════════════

test_help() {
  reset_store
  run --help
  expect_rc 0 "help" || return 0
  case "$OUT" in
    *"scripts/pr-assets-upload.sh --repo <owner/name> --pr <number> <file>..."*"--mode pr-assets"*) pass "help prints the usage contract" ;;
    *) fail "help: usage text missing the command or the preflight mode" ;;
  esac
}

test_usage_errors() {
  reset_store
  local before; before="$(main_sha)"
  run
  expect_rc 1 "no arguments" || return 0
  run --smoke --repo nathanjohnpayne/mergepath "$T/img/desktop.png"
  expect_rc 1 "--smoke with --repo" || return 0
  run --repo nathanjohnpayne/mergepath --pr 0 "$T/img/desktop.png"
  expect_rc 1 "--pr 0" || return 0
  run --repo nathanjohnpayne/mergepath --pr abc "$T/img/desktop.png"
  expect_rc 1 "--pr abc" || return 0
  run --repo mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 1 "--repo without owner" || return 0
  run --repo nathanjohnpayne/mergepath --pr 42
  expect_rc 1 "no files" || return 0
  expect_store_unchanged "$before" "usage errors" || return 0
  [ ! -s "$MOCK_DIR/gh.log" ] || { fail "usage errors called gh"; return 0; }
  pass "usage errors exit 1 before any gh call"
}

test_non_image_refused() {
  reset_store
  local before f; before="$(main_sha)"
  for f in fake.png notes.txt logo.svg UPPER.PNG; do
    run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png" "$T/img/$f"
    expect_rc 2 "non-image $f" || return 0
  done
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/logo.svg"
  case "$ERR" in *"SVG is refused"*) ;; *) fail "svg refusal did not say why: $ERR"; return 0 ;; esac
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/missing.png"
  expect_rc 2 "missing file" || return 0
  expect_store_unchanged "$before" "non-image" || return 0
  [ ! -s "$MOCK_DIR/gh.log" ] || { fail "a refused file still reached gh"; return 0; }
  pass "non-images (wrong content, .txt, .svg, uppercase ext, missing) refused with exit 2 before any gh call"
}

test_bad_names_refused() {
  reset_store
  local before; before="$(main_sha)"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/my file.png"
  expect_rc 2 "name with a space" || return 0
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/.hidden.png"
  expect_rc 2 "dot-leading name" || return 0
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png" "$T/img/dup/desktop.png"
  expect_rc 2 "duplicate basename in one call" || return 0
  expect_store_unchanged "$before" "bad names" || return 0
  pass "unsafe or duplicate file names refused with exit 2"
}

test_credential_required_and_fine_grained() {
  reset_store
  local before; before="$(main_sha)"
  RUN_TOKEN="" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "missing token" || return 0
  case "$ERR" in *"--mode pr-assets"*) ;; *) fail "missing-token message does not point at preflight"; return 0 ;; esac
  RUN_TOKEN="ghp_classicTESTONLY000000000000000000000000" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "classic token" || return 0
  expect_store_unchanged "$before" "credential" || return 0
  pass "missing or non-fine-grained credential refused with exit 3"
}

test_ambient_gh_token_not_used() {
  reset_store
  # Only GH_TOKEN, no scoped credential: must refuse, not fall back.
  set +e
  ( cd "$T" && GH_TOKEN="$TOKEN" PR_ASSETS_TEST_REMOTE_URL="file://$BARE" TMPDIR="$T/tmp" \
      "$SCRIPT" --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png" >"$T/out" 2>"$T/err" )
  RC=$?
  set -e
  ERR="$(cat "$T/err")"
  expect_rc 3 "ambient GH_TOKEN only" || return 0
  pass "ambient GH_TOKEN is not used as the upload credential"
}

test_wrong_identity_refused() {
  reset_store
  local before; before="$(main_sha)"
  printf '%s' '{"login":"nathanpayne-claude"}' > "$MOCK_DIR/user.json"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "reviewer identity" || return 0
  expect_store_unchanged "$before" "wrong identity" || return 0
  if grep -q 'push' "$MOCK_DIR/git.argv.log" 2>/dev/null; then fail "wrong identity still pushed"; return 0; fi
  pass "a credential that reads as another login is refused before any git operation"
}

test_wrong_destination_refused() {
  reset_store
  local before; before="$(main_sha)"
  printf '%s' '{"full_name":"someone-else/pr-assets","visibility":"public","private":false,"default_branch":"main","permissions":{"push":true}}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__pr-assets.json"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "store renamed/transferred" || return 0
  write_fixtures
  printf '%s' '{"full_name":"nathanjohnpayne/pr-assets","visibility":"private","private":true,"default_branch":"main","permissions":{"push":true}}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__pr-assets.json"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "store not public" || return 0
  write_fixtures
  printf '%s' '{"full_name":"nathanjohnpayne/pr-assets","visibility":"public","private":false,"default_branch":"main","permissions":{"push":false}}' \
    > "$MOCK_DIR/repos__nathanjohnpayne__pr-assets.json"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "no push access" || return 0
  write_fixtures
  RUN_REMOTE="https://example.invalid/evil.git" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "non-file test remote" || return 0
  expect_store_unchanged "$before" "wrong destination" || return 0
  if grep -q 'push' "$MOCK_DIR/git.argv.log" 2>/dev/null; then fail "wrong destination still pushed"; return 0; fi
  pass "a destination other than the public, writable nathanjohnpayne/pr-assets is refused"
}

test_private_source_refused() {
  reset_store
  local before; before="$(main_sha)"
  run --repo nathanjohnpayne/secret-thing --pr 42 "$T/img/desktop.png"
  expect_rc 3 "private source" || return 0
  case "$ERR" in
    *"approved private method"*"report that none is available"*) ;;
    *) fail "private refusal does not tell the caller what to do: $ERR"; return 0 ;;
  esac
  run --repo nathanjohnpayne/corp --pr 42 "$T/img/desktop.png"
  expect_rc 3 "internal source" || return 0
  run --repo nathanjohnpayne/not-visible --pr 42 "$T/img/desktop.png"
  expect_rc 3 "unreadable (private, 404) source" || return 0
  case "$ERR" in *"approved private method"*) ;; *) fail "404 refusal does not point at a private method"; return 0 ;; esac
  run --repo someone-else/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 3 "other owner" || return 0
  run --repo nathanjohnpayne/mergepath --pr 9999 "$T/img/desktop.png"
  expect_rc 3 "PR does not exist" || return 0
  expect_store_unchanged "$before" "source refusals" || return 0
  pass "private, internal, unreadable, other-owner sources and a missing PR are refused with exit 3"
}

test_happy_path_sha_pinned() {
  reset_store
  local before after parent n line want_re count
  before="$(main_sha)"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png" "$T/img/phone.png" "$T/img/shot.jpg" "$T/img/anim.gif" "$T/img/pic.webp"
  expect_rc 0 "happy path" || return 0
  after="$(main_sha)"
  [ "$after" != "$before" ] || { fail "happy path: store did not move"; return 0; }
  parent="$("$REAL_GIT" --git-dir="$BARE" rev-parse "$after^")"
  [ "$parent" = "$before" ] || { fail "happy path: not one fast-forward commit on top of main"; return 0; }
  n="$("$REAL_GIT" --git-dir="$BARE" rev-list --count "$before..$after")"
  [ "$n" = "1" ] || { fail "happy path: expected 1 commit, got $n"; return 0; }
  count="$(printf '%s\n' "$OUT" | grep -c . || true)"
  [ "$count" = "5" ] || { fail "happy path: expected 5 stdout lines, got $count: $OUT"; return 0; }
  for f in desktop.png phone.png shot.jpg anim.gif pic.webp; do
    line="![$f](https://raw.githubusercontent.com/nathanjohnpayne/pr-assets/$after/mergepath/42/$f)"
    printf '%s\n' "$OUT" | grep -qxF "$line" || { fail "happy path: missing line $line"; return 0; }
    if ! cmp -s <("$REAL_GIT" --git-dir="$BARE" cat-file blob "$after:mergepath/42/$f") "$T/img/$f"; then
      fail "happy path: stored $f differs from the source bytes"; return 0
    fi
  done
  want_re='^[0-9a-f]{40}$'
  printf '%s' "$after" | grep -Eq "$want_re" || { fail "pinned SHA is not a full 40-hex SHA"; return 0; }
  "$REAL_GIT" --git-dir="$BARE" log -1 --format=%B "$after" | grep -qxF 'Refs nathanjohnpayne/mergepath#42' \
    || { fail "happy path: commit message lacks the Refs line"; return 0; }
  "$REAL_GIT" --git-dir="$BARE" cat-file -e "$after:mergepath/7/existing.png" \
    || { fail "happy path: an existing file vanished"; return 0; }
  pass "upload commits once on top of main and prints one full-SHA-pinned line per file"
}

test_no_secret_leak_and_get_only() {
  reset_store
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "leak check upload" || return 0
  if printf '%s\n%s\n' "$OUT" "$ERR" | grep -qF "$TOKEN"; then fail "token printed"; return 0; fi
  if grep -qF "$TOKEN" "$MOCK_DIR/git.argv.log" "$MOCK_DIR/gh.log"; then fail "token in a command's argv"; return 0; fi
  if grep -q 'push.*--force\|push.* -f \|+[0-9a-f]\{40\}:' "$MOCK_DIR/git.argv.log"; then fail "a forced push was attempted"; return 0; fi
  grep -q 'push.*:refs/heads/main$' "$MOCK_DIR/git.argv.log" || { fail "push did not target refs/heads/main"; return 0; }
  # gh api is a GET unless a method, a field or an input body says otherwise.
  if grep -Eq -- '--method [^G]|(^| )-X |(^| )-[fF] |--field|--raw-field|--input' "$MOCK_DIR/gh.log"; then
    fail "a gh call was not a GET: $(cat "$MOCK_DIR/gh.log")"; return 0
  fi
  if grep -q 'repos/nathanjohnpayne/mergepath/git\|/refs' "$MOCK_DIR/gh.log"; then fail "touched source refs over the API"; return 0; fi
  pass "token never printed or in argv; push is a plain fast-forward to main; every gh call is a GET"
}

test_no_source_ref_created() {
  reset_store
  local src="$T/source.git" clone="$T/source-clone" before_refs after_refs
  rm -rf "$src" "$clone"
  "$REAL_GIT" init -q --bare "$src"
  "$REAL_GIT" init -q "$clone"
  printf 'code\n' > "$clone/app.txt"
  "$REAL_GIT" -C "$clone" add -A
  "$REAL_GIT" -C "$clone" commit -qm init
  "$REAL_GIT" -C "$clone" remote add origin "$src"
  "$REAL_GIT" -C "$clone" push -q origin HEAD:refs/heads/main
  before_refs="$("$REAL_GIT" ls-remote "$src"; "$REAL_GIT" -C "$clone" for-each-ref)"
  RUN_CWD="$clone" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "upload from inside a source checkout" || return 0
  after_refs="$("$REAL_GIT" ls-remote "$src"; "$REAL_GIT" -C "$clone" for-each-ref)"
  [ "$before_refs" = "$after_refs" ] || { fail "source repository refs changed"; return 0; }
  # The only git calls allowed against the caller's directory are the two
  # read-only queries for its identity and signing settings. Match the
  # resolved path too: the script logs `pwd -P`, which differs from $clone
  # where the temp directory sits behind a symlink (macOS /var).
  local clone_real
  clone_real="$(cd "$clone" && pwd -P)"
  if grep -F -e "$clone" -e "$clone_real" -e "$src" "$MOCK_DIR/git.argv.log" \
       | grep -v -x -F \
           -e "-C $clone_real config --type=bool --get commit.gpgsign" \
           -e "-C $clone_real config -z --get-regexp ^(user|author|committer|gpg)\\." \
       | grep -q .; then
    fail "git ran against the source repository beyond the read-only config queries"; return 0
  fi
  pass "no ref is created in the source repository (ls-remote and local refs unchanged; only config reads run there)"
}

test_relative_paths() {
  reset_store
  local after
  mkdir -p "$T/img/sub"
  png sub/rel.png "relative-bytes"
  RUN_CWD="$T/img" run --repo nathanjohnpayne/mergepath --pr 42 desktop.png sub/rel.png
  expect_rc 0 "relative input paths" || return 0
  after="$(main_sha)"
  "$REAL_GIT" --git-dir="$BARE" cat-file -e "$after:mergepath/42/desktop.png" || { fail "relative: desktop.png missing"; return 0; }
  cmp -s <("$REAL_GIT" --git-dir="$BARE" cat-file blob "$after:mergepath/42/rel.png") "$T/img/sub/rel.png" \
    || { fail "relative: sub/rel.png bytes differ"; return 0; }
  pass "relative input paths are resolved against the caller's directory, not the work repository"
}

test_push_does_not_see_caller_netrc() {
  reset_store
  printf 'machine github.com login someone password not-the-scoped-token\n' > "$HOME/.netrc"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  rm -f "$HOME/.netrc"
  expect_rc 0 "upload with a caller netrc present" || return 0
  local h
  h="$(tail -1 "$MOCK_DIR/push.home")"
  [ -n "$h" ] && [ "$h" != "$HOME" ] || { fail "push ran with the caller's HOME ($h)"; return 0; }
  [ ! -e "$h/.netrc" ] || { fail "push HOME carries a .netrc"; return 0; }
  pass "network git runs with an isolated HOME, so the caller's ~/.netrc cannot supply a credential"
}

test_collision_refused_identical_reused() {
  reset_store
  local first second
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "first upload" || return 0
  first="$(main_sha)"
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/dup/desktop.png"
  expect_rc 2 "different content under an existing name" || return 0
  expect_store_unchanged "$first" "collision" || return 0
  case "$ERR" in *"different content"*) ;; *) fail "collision message unclear: $ERR"; return 0 ;; esac
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "identical re-upload" || return 0
  expect_store_unchanged "$first" "identical re-upload" || return 0
  [ "$OUT" = "![desktop.png](https://raw.githubusercontent.com/nathanjohnpayne/pr-assets/$first/mergepath/42/desktop.png)" ] \
    || { fail "identical re-upload line not pinned to the commit holding the file: $OUT"; return 0; }
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png" "$T/img/phone.png"
  expect_rc 0 "mixed identical + new" || return 0
  second="$(main_sha)"
  [ "$("$REAL_GIT" --git-dir="$BARE" rev-parse "$second^")" = "$first" ] || { fail "mixed upload not one commit"; return 0; }
  printf '%s\n' "$OUT" | grep -qxF "![desktop.png](https://raw.githubusercontent.com/nathanjohnpayne/pr-assets/$second/mergepath/42/desktop.png)" \
    || { fail "mixed upload: identical file not pinned to the new commit"; return 0; }
  pass "a different file under an existing name is refused; identical content is not re-uploaded"
}

test_concurrent_push_retried() {
  reset_store
  local before after parent race
  before="$(main_sha)"
  MOCK_RACE=once run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "upload racing one concurrent upload" || return 0
  after="$(main_sha)"
  parent="$("$REAL_GIT" --git-dir="$BARE" rev-parse "$after^")"
  race="$("$REAL_GIT" --git-dir="$BARE" rev-parse "$parent^")"
  [ "$race" = "$before" ] || { fail "race: history is not seed -> race -> ours"; return 0; }
  "$REAL_GIT" --git-dir="$BARE" cat-file -e "$after:other/1/race-1.png" || { fail "race: concurrent upload lost"; return 0; }
  "$REAL_GIT" --git-dir="$BARE" cat-file -e "$after:mergepath/42/desktop.png" || { fail "race: our file missing"; return 0; }
  [ "$OUT" = "![desktop.png](https://raw.githubusercontent.com/nathanjohnpayne/pr-assets/$after/mergepath/42/desktop.png)" ] \
    || { fail "race: line not pinned to the rebuilt commit: $OUT"; return 0; }
  case "$ERR" in *"concurrent upload"*) ;; *) fail "race: retry not reported"; return 0 ;; esac
  pass "a push rejected by a concurrent upload is re-fetched, rebuilt and retried without force"
}

test_concurrent_collision_refused() {
  reset_store
  local raced
  MOCK_RACE=once MOCK_RACE_PATH="mergepath/42/desktop.png" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 2 "concurrent upload of the same name" || return 0
  raced="$(main_sha)"
  [ "$("$REAL_GIT" --git-dir="$BARE" log -1 --format=%s "$raced")" = "race 1" ] \
    || { fail "concurrent collision: our commit landed over the other upload"; return 0; }
  pass "a collision introduced by a concurrent upload is re-checked and refused"
}

test_push_retries_bounded() {
  reset_store
  MOCK_RACE=always run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 4 "store moving on every attempt" || return 0
  [ "$(cat "$MOCK_DIR/race.count")" = "3" ] || { fail "expected exactly 3 push attempts, got $(cat "$MOCK_DIR/race.count")"; return 0; }
  if "$REAL_GIT" --git-dir="$BARE" cat-file -e "refs/heads/main:mergepath/42/desktop.png" 2>/dev/null; then
    fail "bounded retry: our file landed anyway"; return 0
  fi
  pass "push retries are bounded (3 attempts, then exit 4, nothing forced)"
}

test_smoke_mode() {
  reset_store
  local after
  run --smoke "$T/img/desktop.png"
  expect_rc 0 "smoke upload" || return 0
  after="$(main_sha)"
  [ "$OUT" = "![desktop.png](https://raw.githubusercontent.com/nathanjohnpayne/pr-assets/$after/_smoke/desktop.png)" ] \
    || { fail "smoke: unexpected line: $OUT"; return 0; }
  if grep -q 'repos/nathanjohnpayne/mergepath' "$MOCK_DIR/gh.log"; then fail "smoke read a source repository"; return 0; fi
  pass "--smoke uploads to _smoke/ and prints a pinned line"
}

make_fake_gpg() {
  cat > "$T/bin/fake-gpg" <<'EOF'
#!/bin/sh
cat >/dev/null
if [ "${FAKE_GPG_FAIL:-0}" = 1 ]; then echo "fake-gpg: agent locked" >&2; exit 2; fi
printf '[GNUPG:] BEGIN_SIGNING\n[GNUPG:] SIG_CREATED D 1 8 00 0 0 FAKE\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nZmFrZS1zaWduYXR1cmU=\n-----END PGP SIGNATURE-----\n'
EOF
  chmod +x "$T/bin/fake-gpg"
}

test_signing_config_honoured() {
  reset_store
  local after
  make_fake_gpg
  cp "$T/gitconfig" "$T/gitconfig.plain"
  cat >> "$T/gitconfig" <<EOF
[commit]
	gpgsign = true
[user]
	signingkey = TESTKEY
[gpg]
	program = $T/bin/fake-gpg
EOF
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  if [ "$RC" -ne 0 ]; then cp "$T/gitconfig.plain" "$T/gitconfig"; fail "signed upload: exit $RC: $ERR"; return 0; fi
  after="$(main_sha)"
  if ! "$REAL_GIT" --git-dir="$BARE" cat-file commit "$after" | grep -q '^gpgsig'; then
    cp "$T/gitconfig.plain" "$T/gitconfig"; fail "commit.gpgSign=true did not produce a signed commit"; return 0
  fi
  case "$ERR" in *unsigned*) cp "$T/gitconfig.plain" "$T/gitconfig"; fail "signed commit reported as unsigned"; return 0 ;; esac
  local before_fail; before_fail="$after"
  FAKE_GPG_FAIL=1 run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/phone.png"
  cp "$T/gitconfig.plain" "$T/gitconfig"
  expect_rc 4 "signing failure" || return 0
  expect_store_unchanged "$before_fail" "signing failure" || return 0
  # Unsigned config: pushed, with a warning.
  run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/phone.png"
  expect_rc 0 "unsigned upload" || return 0
  case "$ERR" in *"is unsigned"*) ;; *) fail "unsigned commit not warned about"; return 0 ;; esac
  pass "the commit honours the caller's signing config; a signing failure pushes nothing"
}

# Signing configured only in the invoking repository (not globally) still
# signs: the settings are resolved in the caller's directory, not in the
# temporary store clone where repository-local config does not exist.
test_signing_config_from_caller_repository() {
  reset_store
  local caller="$T/caller-signing" after
  make_fake_gpg
  rm -rf "$caller"
  "$REAL_GIT" init -q "$caller"
  "$REAL_GIT" -C "$caller" config commit.gpgsign true
  "$REAL_GIT" -C "$caller" config user.signingkey TESTKEY
  "$REAL_GIT" -C "$caller" config gpg.program "$T/bin/fake-gpg"
  RUN_CWD="$caller" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "upload with repository-local signing" || return 0
  after="$(main_sha)"
  "$REAL_GIT" --git-dir="$BARE" cat-file commit "$after" | grep -q '^gpgsig' \
    || { fail "repository-local commit.gpgSign in the caller's directory did not produce a signed commit"; return 0; }
  case "$ERR" in *unsigned*) fail "repository-local signed commit reported as unsigned"; return 0 ;; esac
  pass "signing settings are read in the caller's directory, so repository-local signing config applies"
}

# Trace2 records named environment variables (GIT_TRACE2_ENV_VARS) to its
# target; the push credential must never reach a trace file.
test_trace_controls_do_not_record_credential() {
  reset_store
  local t2="$T/trace2.event" t1="$T/trace.classic" t2n="$T/trace2.normal"
  rm -f "$t2" "$t1" "$t2n"
  GIT_TRACE2_EVENT="$t2" GIT_TRACE2="$t2n" GIT_TRACE2_ENV_VARS=PR_ASSETS_PUSH_CREDENTIAL \
    GIT_TRACE="$t1" run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 0 "upload with trace controls set" || return 0
  local trace
  for trace in "$t2" "$t2n" "$t1"; do
    if [ -f "$trace" ] && grep -qF "$TOKEN" "$trace"; then
      fail "the push credential was written to a git trace target"; return 0
    fi
  done
  pass "git trace controls (Trace2 env-var logging included) never record the push credential"
}

test_unconfirmed_commit_not_printed() {
  reset_store
  MOCK_FAIL_CONFIRM=1 run --repo nathanjohnpayne/mergepath --pr 42 "$T/img/desktop.png"
  expect_rc 4 "unconfirmed commit" || return 0
  [ -z "$OUT" ] || { fail "unconfirmed commit still printed links: $OUT"; return 0; }
  pass "links are not printed when the pushed commit cannot be confirmed on GitHub"
}

test_help
test_usage_errors
test_non_image_refused
test_bad_names_refused
test_credential_required_and_fine_grained
test_ambient_gh_token_not_used
test_wrong_identity_refused
test_wrong_destination_refused
test_private_source_refused
test_happy_path_sha_pinned
test_no_secret_leak_and_get_only
test_no_source_ref_created
test_relative_paths
test_push_does_not_see_caller_netrc
test_collision_refused_identical_reused
test_concurrent_push_retried
test_concurrent_collision_refused
test_push_retries_bounded
test_smoke_mode
test_signing_config_honoured
test_signing_config_from_caller_repository
test_trace_controls_do_not_record_credential
test_unconfirmed_commit_not_printed

echo ""
echo "test_pr_assets_upload: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
