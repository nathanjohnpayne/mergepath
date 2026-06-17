#!/usr/bin/env bash
set -euo pipefail

# tests/test_verify_propagation_pr_templated.sh
#
# Fixture-driven tests for the templated-surface arm of
# scripts/workflow/verify-propagation-pr.sh (#323). The templated
# arm renders each templated entry's source against mergepath@<sha>
# with the consumer's facts (loaded via export_consumer_facts) and
# byte-compares against the PR's dest content.
#
# Each case builds a throwaway "mergepath" checkout containing the
# template lib, facts helper, and parse/match helpers, plus a manifest
# with one templated entry. A throwaway "consumer" git repo carries
# the PR's dest content at HEAD. The script under test is invoked
# with $MERGEPATH_CONSUMER set so the consumer-inference step
# doesn't depend on a git remote configuration.
#
# Exit-code contract for the templated surface:
#   0  — re-render matches PR dest content
#   1  — re-render diverges OR render errors (malformed template,
#        strict-mode unset fact, source missing)
#   2  — usage / environment error (covered in the parent test)
#
# Bash 3.2 portable. Runs from
# scripts/ci/check_workflow_verify_propagation_templated.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/workflow/verify-propagation-pr.sh"
[ -x "$VERIFY" ] || { echo "missing or non-executable $VERIFY" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-prop-templated-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# Build a throwaway "mergepath" checkout. Carries:
#   - the trusted helpers (parse_manifest_paths, match_protected_paths,
#     template-substitution, manifest-fact-helpers)
#   - a manifest with one templated entry + one canonical entry
#   - the templated source template
# The manifest is rebuilt per case (different facts produce different
# expected renders).
build_mergepath() {
  local mp="$1" template_body="$2" frameworks="$3"
  mkdir -p "$mp/scripts/workflow" "$mp/scripts/lib" "$mp/examples"
  cp "$ROOT/scripts/workflow/parse_manifest_paths.sh" "$mp/scripts/workflow/"
  cp "$ROOT/scripts/workflow/match_protected_paths.sh" "$mp/scripts/workflow/"
  cp "$ROOT/scripts/lib/template-substitution.sh" "$mp/scripts/lib/"
  cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$mp/scripts/lib/"
  printf '%s' "$template_body" >"$mp/examples/source.tpl"
  cat >"$mp/.mergepath-sync.yml" <<YAML
version: 1
consumers:
  - name: alpha
    repo: example/alpha
    facts:
      frameworks: [$frameworks]
paths:
  - path: examples/source.tpl
    source: examples/source.tpl
    dest: rendered.txt
    type: templated
    consumers:
      - alpha
YAML
}

# Build a consumer git repo with a base (no rendered.txt) → head
# (rendered.txt added with the supplied content). Sets globals
# BASE_SHA / HEAD_SHA.
build_consumer() {
  local cdir="$1" pr_content="$2" dest_mode="${3:-100644}"
  mkdir -p "$cdir"
  git_quiet -C "$cdir" init -q
  printf 'app code\n' >"$cdir/app.ts"
  git_quiet -C "$cdir" add -A
  git_quiet -C "$cdir" commit -q -m base
  BASE_SHA=$(git -C "$cdir" rev-parse HEAD)
  printf '%s' "$pr_content" >"$cdir/rendered.txt"
  git_quiet -C "$cdir" add -A
  # Record the executable bit in the git INDEX, not via a filesystem
  # chmod: under core.filemode=false (some CI images / mode-insensitive
  # filesystems) git ignores the on-disk exec bit and would commit 100644
  # regardless, silently breaking Cases 6/7. `git update-index --chmod=+x`
  # writes mode 100755 directly into the index — same approach Case 5 uses
  # for its fixture (CodeRabbit on PR #475).
  [ "$dest_mode" = "100755" ] && git_quiet -C "$cdir" update-index --chmod=+x rendered.txt
  git_quiet -C "$cdir" commit -q -m head
  HEAD_SHA=$(git -C "$cdir" rev-parse HEAD)
}

run_verify() {  # $1=mp $2=consumer; sets RC, STDOUT_FILE, STDERR_FILE
  STDOUT_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-out.XXXXXX")
  STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-err.XXXXXX")
  set +e
  MERGEPATH_CONSUMER=alpha "$VERIFY" "$1" "$2" "$BASE_SHA" "$HEAD_SHA" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RC=$?
  set -e
}

# ---------------------------------------------------------------------------
# Case 1 — pass: PR dest matches re-render.
#
# Template has a `>>> if frameworks contains react` block; consumer
# carries `frameworks: [react]`, so the block is included. The PR's
# dest carries the exact rendered output. Expect:
#   - exit 0
#   - "[mergepath-verify: templated-render] rendered.txt alpha examples/source.tpl"
#     on stdout
# ---------------------------------------------------------------------------
TEMPLATE_BODY='hello {{name}}
// >>> if frameworks contains react
react block
// <<<
trailing line
'
# What the template renders to with name=mergepath, frameworks=[react]:
EXPECTED_RENDER='hello mergepath
react block
trailing line
'
MP1="$WORKDIR/mp1"; build_mergepath "$MP1" "$TEMPLATE_BODY" "react"
# Append a `facts.name` so {{name}} resolves.
# We rebuild the manifest carefully with both facts.
cat >"$MP1/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: alpha
    repo: example/alpha
    facts:
      frameworks: [react]
      name: mergepath
paths:
  - path: examples/source.tpl
    source: examples/source.tpl
    dest: rendered.txt
    type: templated
    consumers:
      - alpha
YAML
C1="$WORKDIR/c1"
build_consumer "$C1" "$EXPECTED_RENDER"
run_verify "$MP1" "$C1"
if [ "$RC" -ne 0 ]; then
  fail "Case 1 pass: expected exit 0, got $RC"
  echo "stdout:" >&2; sed 's/^/    /' "$STDOUT_FILE" >&2
  echo "stderr:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
elif ! grep -qF '[mergepath-verify: templated-render] rendered.txt alpha examples/source.tpl' "$STDOUT_FILE"; then
  fail "Case 1 pass: missing structured tag-reply line on stdout"
  echo "stdout was:" >&2; sed 's/^/    /' "$STDOUT_FILE" >&2
else
  pass "Case 1: PR dest matches re-render → exit 0, structured tag line emitted"
fi

# ---------------------------------------------------------------------------
# Case 2 — drift: PR dest content differs from re-render.
# Same fixtures as Case 1 but the PR dest carries an extra line.
# Expect exit 1 + a divergence diagnostic in stderr.
# ---------------------------------------------------------------------------
C2="$WORKDIR/c2"
build_consumer "$C2" "${EXPECTED_RENDER}HAND EDITED EXTRA LINE
"
run_verify "$MP1" "$C2"
if [ "$RC" -ne 1 ]; then
  fail "Case 2 drift: expected exit 1, got $RC"
  echo "stdout:" >&2; sed 's/^/    /' "$STDOUT_FILE" >&2
  echo "stderr:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
elif ! grep -q 'diverges from PR content' "$STDERR_FILE"; then
  fail "Case 2 drift: stderr missing 'diverges from PR content' diagnostic"
  echo "stderr was:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
elif ! grep -q 'Templated re-render mismatch' "$STDERR_FILE"; then
  fail "Case 2 drift: stderr missing typed-summary header 'Templated re-render mismatch'"
  echo "stderr was:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
else
  pass "Case 2: PR dest diverges from re-render → exit 1, typed diagnostic"
fi

# ---------------------------------------------------------------------------
# Case 3 — template syntax error: malformed `>>> if` (no closing `<<<`).
# Expect exit 1 + a template-error diagnostic in stderr.
# ---------------------------------------------------------------------------
BAD_TEMPLATE='line one
// >>> if frameworks contains react
unclosed block
'
MP3="$WORKDIR/mp3"; build_mergepath "$MP3" "$BAD_TEMPLATE" "react"
C3="$WORKDIR/c3"
# PR has SOMETHING for dest; content is irrelevant — render errors
# before the byte-compare.
build_consumer "$C3" "doesnt matter
"
run_verify "$MP3" "$C3"
if [ "$RC" -ne 1 ]; then
  fail "Case 3 template error: expected exit 1, got $RC"
  echo "stderr:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
elif ! grep -q 'template render error\|Templated re-render error' "$STDERR_FILE"; then
  fail "Case 3 template error: stderr missing template-render error diagnostic"
  echo "stderr was:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
else
  pass "Case 3: malformed template (unclosed >>> if) → exit 1, template error"
fi

# ---------------------------------------------------------------------------
# Case 4 — strict-mode unset fact: template references {{undeclared}};
# MERGEPATH_TEMPLATE_STRICT=1 makes the render fail with rc=3, which the
# verifier surfaces as exit 1 with a render-error diagnostic.
# ---------------------------------------------------------------------------
STRICT_TEMPLATE='value: <{{undeclared}}>
'
MP4="$WORKDIR/mp4"; build_mergepath "$MP4" "$STRICT_TEMPLATE" "react"
C4="$WORKDIR/c4"
build_consumer "$C4" "doesnt matter
"
# Run with strict mode on. MERGEPATH_TEMPLATE_STRICT is honored by the
# template lib at render time.
STDOUT_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-out.XXXXXX")
STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-err.XXXXXX")
set +e
MERGEPATH_CONSUMER=alpha MERGEPATH_TEMPLATE_STRICT=1 \
  "$VERIFY" "$MP4" "$C4" "$BASE_SHA" "$HEAD_SHA" \
  > "$STDOUT_FILE" 2> "$STDERR_FILE"
RC=$?
set -e
if [ "$RC" -ne 1 ]; then
  fail "Case 4 strict-mode: expected exit 1, got $RC"
  echo "stderr:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
elif ! grep -q 'render failed\|template render error\|Templated re-render error' "$STDERR_FILE"; then
  fail "Case 4 strict-mode: stderr missing render-failure diagnostic"
  echo "stderr was:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
else
  pass "Case 4: strict-mode unset fact → exit 1, render-failure diagnostic"
fi

# ---------------------------------------------------------------------------
# Case 5 — mode tampering (chmod +x): PR dest matches rendered bytes but
# has tree entry mode 100755 instead of 100644. Without the tree-entry
# check (codex P1 #329 round 2), the byte-only verifier let metadata
# tampering pass; the new check should reject it.
# ---------------------------------------------------------------------------
TEMPLATE5='greeting={{name}}, frameworks={{frameworks}}
'
MP5="$WORKDIR/mp5"; build_mergepath "$MP5" "$TEMPLATE5" "react"
C5="$WORKDIR/c5"
RENDERED5='greeting=, frameworks=react
'
mkdir -p "$C5"
git_quiet -C "$C5" init -q
printf 'app code\n' >"$C5/app.ts"
git_quiet -C "$C5" add -A
git_quiet -C "$C5" commit -q -m base
BASE_SHA=$(git -C "$C5" rev-parse HEAD)
printf '%s' "$RENDERED5" >"$C5/rendered.txt"
git_quiet -C "$C5" add -A
# Force the exec bit IN THE INDEX regardless of the filesystem's
# core.filemode. The prior version used `chmod +x` alone, which only
# updates the working tree — on a filesystem that ignores mode bits
# (Windows/WSL, some networked filesystems) or in a repo with
# `core.filemode=false`, git still records `100644 blob` and the
# fixture-setup guard below fails BEFORE exercising the actual
# mode-tampering check. `git update-index --chmod=+x` writes mode
# 100755 directly into the index, capturing the executable bit on
# the next commit even when filesystem mode bits are unavailable.
# (CR Minor on PR #329, addressed as #329 follow-up.)
git_quiet -C "$C5" update-index --chmod=+x rendered.txt
git_quiet -C "$C5" commit -q -m head
HEAD_SHA=$(git -C "$C5" rev-parse HEAD)
fixture_entry=$(git -C "$C5" ls-tree HEAD -- rendered.txt | awk '{print $1, $2}')
if [ "$fixture_entry" != "100755 blob" ]; then
  fail "Case 5 fixture setup: expected 100755 blob, got [$fixture_entry] — update-index --chmod=+x didn't take"
else
  run_verify "$MP5" "$C5"
  if [ "$RC" -ne 1 ]; then
    fail "Case 5 mode-tampering: expected exit 1, got $RC"
    echo "stdout:" >&2; sed 's/^/    /' "$STDOUT_FILE" >&2
    echo "stderr:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
  elif ! grep -q 'tree entry.*100755\|mode/type tampering' "$STDERR_FILE"; then
    fail "Case 5 mode-tampering: stderr missing tree-entry diagnostic"
    echo "stderr was:" >&2; sed 's/^/    /' "$STDERR_FILE" >&2
  else
    pass "Case 5: mode tampering (chmod +x) → exit 1, tree-entry diagnostic"
  fi
fi

# ---------------------------------------------------------------------------
# Case 6 — executable templated source: rendered dest must INHERIT +x (#471).
# Before the fix the verifier hardcoded `100644 blob` and would reject a
# faithfully-rendered executable template; now it derives the expected mode
# from the source. A no-facts template renders to itself.
# ---------------------------------------------------------------------------
EXEC_TEMPLATE='#!/usr/bin/env bash
echo hello
'
MP6="$WORKDIR/mp6"; build_mergepath "$MP6" "$EXEC_TEMPLATE" ""
chmod +x "$MP6/examples/source.tpl"
C6="$WORKDIR/c6"; build_consumer "$C6" "$EXEC_TEMPLATE" 100755
run_verify "$MP6" "$C6"
if [ "$RC" -ne 0 ]; then
  fail "Case 6 exec-template pass: expected exit 0, got $RC"
  { echo "stderr:"; sed 's/^/  /' "$STDERR_FILE"; } >&2
else
  pass "Case 6: executable templated source + executable dest → exit 0 (mode inherited)"
fi

# ---------------------------------------------------------------------------
# Case 7 — executable source but dest rendered NON-executable → mode drift.
# The fix must still catch a mode FLIP relative to the (now executable) source.
# ---------------------------------------------------------------------------
MP7="$WORKDIR/mp7"; build_mergepath "$MP7" "$EXEC_TEMPLATE" ""
chmod +x "$MP7/examples/source.tpl"
C7="$WORKDIR/c7"; build_consumer "$C7" "$EXEC_TEMPLATE" 100644
run_verify "$MP7" "$C7"
if [ "$RC" -ne 1 ]; then
  fail "Case 7 exec-source mode-drift: expected exit 1, got $RC"
else
  pass "Case 7: executable source but non-executable dest → exit 1 (mode drift caught)"
fi

# ---------------------------------------------------------------------------
# Case 8 — source mode is read from the COMMITTED git tree, not the on-disk
# exec bit (#475 / CodeRabbit + Codex). This is the PRODUCTION path: a real
# MERGEPATH_DIR is a git checkout. The source is committed as 100755 but its
# on-disk exec bit is then CLEARED, so a filesystem `-x` read would see
# 100644 and wrongly reject the executable dest as drift. Only reading the
# git mode (100755) makes the faithful render pass — a precise discriminator
# for the git-tree-mode fix.
# ---------------------------------------------------------------------------
EXEC_TEMPLATE8='#!/usr/bin/env bash
echo run
'
MP8="$WORKDIR/mp8"; build_mergepath "$MP8" "$EXEC_TEMPLATE8" ""
git_quiet -C "$MP8" init -q
git_quiet -C "$MP8" add -A
git_quiet -C "$MP8" update-index --chmod=+x examples/source.tpl
git_quiet -C "$MP8" commit -q -m mp
chmod -x "$MP8/examples/source.tpl"   # on-disk bit now disagrees with git (100755)
# Assert the precondition actually held: if the filesystem ignored chmod -x
# (mode-insensitive FS), the on-disk bit would still be set and Case 8 would
# pass for the WRONG reason (filesystem read also seeing 100755), not because
# the verifier read the git tree. Fail loudly instead (CodeRabbit on PR #475).
if [ -x "$MP8/examples/source.tpl" ]; then
  fail "Case 8 precondition: chmod -x did not clear the on-disk exec bit (mode-insensitive FS); discriminator invalid"
else
C8="$WORKDIR/c8"; build_consumer "$C8" "$EXEC_TEMPLATE8" 100755
run_verify "$MP8" "$C8"
if [ "$RC" -ne 0 ]; then
  fail "Case 8 git-mode source read: expected exit 0, got $RC"
  { echo "stderr:"; sed 's/^/  /' "$STDERR_FILE"; } >&2
else
  pass "Case 8: source mode read from git tree (on-disk bit cleared) → exec dest passes"
fi
fi

echo ""
echo "test_verify_propagation_pr_templated: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
