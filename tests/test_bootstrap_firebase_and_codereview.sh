#!/usr/bin/env bash
# tests/test_bootstrap_firebase_and_codereview.sh
#
# Validates scripts/bootstrap/firebase-and-codereview.sh (sub-D / #206).
#
# Strategy: PATH-shim `firebase`, `gh`, and `yq` so each invocation is
# recorded to a log file and tests can assert command shape + flag set
# without contacting Firebase / GitHub / running yq's real edit. We
# drive the stage end-to-end via the wizard with stages A/B/C/E
# behaviors stubbed/skipped where appropriate, then assert against the
# log.
#
# Cases:
#   1. firebase=none  → zero firebase invocations.
#   2. firebase=dev   → 1 projects:create call.
#   3. firebase=dev+prod → 2 projects:create calls.
#   4. visibility=public → no yq flip + no .coderabbit.yml delete.
#   5. visibility=private → yq flip + delete + commit + push.
#   6. codex_app=n → "NOT requested" log + no Codex URLs printed.
#   7. codex_app=y → all 3 install URLs printed.
#   8. State file records firebase-and-codereview on happy path.
#   9. SHIM_EXIT_FIREBASE=1 → stage fails closed, no state entry.
#  10. Dry-run produces a plan without invoking firebase / gh.
#
# Requires: bash 3.2+, rsync + yq (real, for sub-B to work).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-new-repo.sh"
FIREBASE_SETUP_SCRIPT="$ROOT/scripts/firebase/op-firebase-setup"

if ! command -v rsync >/dev/null 2>&1; then
  echo "SKIP: rsync not installed" >&2; exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed" >&2; exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: non-mikefarah yq" >&2; exit 0
fi

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }
[ -x "$FIREBASE_SETUP_SCRIPT" ] || { echo "missing or non-executable $FIREBASE_SETUP_SCRIPT" >&2; exit 1; }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-firebase-codereview.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Static setup contract: Firebase Functions v2 deploy analysis needs
# secretmanager.secrets.get for defineSecret() declarations.
grep -Fq 'roles/secretmanager.viewer' "$FIREBASE_SETUP_SCRIPT" \
  && pass "op-firebase-setup grants Secret Manager metadata reads for functions secrets" \
  || fail "op-firebase-setup must grant roles/secretmanager.viewer for Firebase Functions defineSecret deploys"

# --- build fixture mergepath ----------------------------------------------
# Sub-B (template-mirror) rsyncs from a fixture mergepath into the
# target. Sub-D then operates on the resulting target. We populate the
# fixture with a minimal .github/review-policy.yml (coderabbit
# enabled) + a .coderabbit.yml stub so the private-visibility path has
# real files to flip + delete.
FAKE_MP="$WORKDIR/fake-mp"
mkdir -p "$FAKE_MP"/{scripts/bootstrap,scripts/ci,scripts/sync,.github/workflows,docs/agents,tests,scripts/firebase}
echo "# mergepath" >"$FAKE_MP/README.md"
echo "Mergepath brand" >"$FAKE_MP/BRAND.md"
echo "ai ctx" >"$FAKE_MP/.ai_context.md"
echo "overview" >"$FAKE_MP/docs/agents/repository-overview.md"
echo "Security" >"$FAKE_MP/SECURITY.md"
cat >"$FAKE_MP/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
extra_top_level_dirs: [mergepath, packaging]
EOF
cat >"$FAKE_MP/.github/review-policy.yml" <<'EOF'
external_review_threshold: 300
coderabbit:
  enabled: true
EOF
cat >"$FAKE_MP/.coderabbit.yml" <<'EOF'
language: en-US
EOF

# Stage modules — copy the real ones in so the wizard's source line
# picks them up from the fixture mergepath.
cp "$ROOT/scripts/bootstrap/_lib.sh"                    "$FAKE_MP/scripts/bootstrap/_lib.sh"
cp "$ROOT/scripts/bootstrap/substitute.sh"              "$FAKE_MP/scripts/bootstrap/substitute.sh"
cp "$ROOT/scripts/bootstrap/template-mirror.sh"         "$FAKE_MP/scripts/bootstrap/template-mirror.sh"
cp "$ROOT/scripts/bootstrap/github-infra.sh"            "$FAKE_MP/scripts/bootstrap/github-infra.sh"
cp "$ROOT/scripts/bootstrap/firebase-and-codereview.sh" "$FAKE_MP/scripts/bootstrap/firebase-and-codereview.sh"
cp "$ROOT/scripts/bootstrap/board-and-summary.sh"       "$FAKE_MP/scripts/bootstrap/board-and-summary.sh"
cp "$ROOT/scripts/bootstrap-new-repo.sh"                "$FAKE_MP/scripts/bootstrap-new-repo.sh"

# Provide a stub op-firebase-setup so stage D's invocation lands on
# something. The shim doesn't need to do anything — bootstrap::run
# captures its invocation in the bootstrap log + the firebase shim
# only fires on real `firebase` calls.
cat >"$FAKE_MP/scripts/firebase/op-firebase-setup" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub op-firebase-setup for tests. Logs invocation to $OP_FB_SETUP_LOG.
echo "op-firebase-setup $*" >>"${OP_FB_SETUP_LOG:-/dev/null}"
exit "${OP_FB_SETUP_EXIT:-0}"
STUB_EOF
chmod +x "$FAKE_MP/scripts/firebase/op-firebase-setup"

git -C "$FAKE_MP" init -q
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture"

# --- shim PATH (gh, firebase, gcloud) -------------------------------------
# Recorded log file + per-subcommand exit overrides.
SHIM_DIR="$WORKDIR/shim-bin"
SHIM_LOG="$WORKDIR/shim.log"
OP_FB_SETUP_LOG="$WORKDIR/op-fb-setup.log"
mkdir -p "$SHIM_DIR"
: >"$SHIM_LOG"

# Real tool symlinks (so coreutils + git + yq + rsync still resolve).
for tool in bash yq git rsync sed awk grep mktemp tr cut tail head wc ls rm cat printf chmod find dirname basename mv mkdir; do
  src=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$src" ] && ln -sf "$src" "$SHIM_DIR/$tool"
done

# Make `op` exist as a stub — github-infra's secret provisioning
# probes it. Always exits 1 to mean "no 1Password item" so the stage
# falls through to BOOTSTRAP_REVIEWER_PAT_VALUE.
cat >"$SHIM_DIR/op" <<'OP_EOF'
#!/usr/bin/env bash
exit 1
OP_EOF
chmod +x "$SHIM_DIR/op"

# gh shim — same pattern as test_bootstrap_github_infra.sh. Records
# every invocation; honors per-subcommand exit overrides.
cat >"$SHIM_DIR/gh" <<'GH_EOF'
#!/usr/bin/env bash
LOG=${SHIM_LOG:?SHIM_LOG not set}
echo "gh $*" >>"$LOG"
case "$1" in
  repo)
    case "$2" in
      create) exit "${SHIM_EXIT_REPO_CREATE:-0}" ;;
      *) exit 0 ;;
    esac ;;
  label)   exit "${SHIM_EXIT_LABEL:-0}" ;;
  api)     exit "${SHIM_EXIT_API:-0}" ;;
  secret)
    if [ "$2" = "set" ]; then cat >/dev/null 2>&1 || true; fi
    exit "${SHIM_EXIT_SECRET:-0}" ;;
  config)
    # gh config get -h github.com user
    echo "nathanpayne-claude"; exit 0 ;;
  auth) exit 0 ;;
  pr)   exit 0 ;;
  *)    exit 0 ;;
esac
GH_EOF
chmod +x "$SHIM_DIR/gh"

# firebase shim — records every invocation; honors SHIM_EXIT_FIREBASE.
# `--data-file <path>` reads the file but discards content; tests
# don't need to inspect the value, just confirm the shape.
cat >"$SHIM_DIR/firebase" <<'FIRE_EOF'
#!/usr/bin/env bash
LOG=${SHIM_LOG:?SHIM_LOG not set}
echo "firebase $*" >>"$LOG"
exit "${SHIM_EXIT_FIREBASE:-0}"
FIRE_EOF
chmod +x "$SHIM_DIR/firebase"

# gcloud shim — preflight_firebase_deps requires it on PATH when
# firebase scope != none. Records invocations + exits 0.
cat >"$SHIM_DIR/gcloud" <<'GCLOUD_EOF'
#!/usr/bin/env bash
LOG=${SHIM_LOG:?SHIM_LOG not set}
echo "gcloud $*" >>"$LOG"
exit 0
GCLOUD_EOF
chmod +x "$SHIM_DIR/gcloud"

SHIM_PATH="$SHIM_DIR:/usr/bin:/bin"

# --- wizard runner --------------------------------------------------------
# The runner re-shims every call so per-test env vars (e.g.,
# SHIM_EXIT_FIREBASE) apply. Stage E (board-and-summary) is skipped
# because it's still a stub and we don't care about it for this test.
run_wizard() {
  PATH="$SHIM_PATH" \
  SHIM_LOG="$SHIM_LOG" \
  OP_FB_SETUP_LOG="$OP_FB_SETUP_LOG" \
  BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
  BOOTSTRAP_SKIP_TOOL_CHECK=1 \
  BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 \
  BOOTSTRAP_AUTO_PROMPT=skip \
  BOOTSTRAP_AUTHOR_NAME="test" \
  BOOTSTRAP_AUTHOR_EMAIL="t@t" \
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 \
  BOOTSTRAP_SKIP_INVITE_PAUSE=1 \
  BOOTSTRAP_REVIEWER_PAT_VALUE="fake-test-pat-1234567890" \
  BOOTSTRAP_SKIP_STAGES="board-and-summary" \
  BOOTSTRAP_SKIP_REMOTE_PUSH=1 \
  "$SCRIPT" "$@"
}

# ========================================================================
# Case 1: firebase=none → zero firebase invocations.
# ========================================================================
: >"$SHIM_LOG"; : >"$OP_FB_SETUP_LOG"
TARGET="$WORKDIR/none-repo"
rm -rf "$TARGET"
set +e
out=$(run_wizard none-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility public \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "firebase=none happy path completes (rc=0)" \
  || fail "firebase=none failed; rc=$ec; out: $out"
if grep -q "^firebase " "$SHIM_LOG"; then
  fail "firebase=none invoked firebase shim ($(grep -c '^firebase ' "$SHIM_LOG") calls); should be 0"
else
  pass "firebase=none results in zero firebase invocations"
fi

# ========================================================================
# Case 2: firebase=dev → exactly 1 projects:create call.
# ========================================================================
: >"$SHIM_LOG"; : >"$OP_FB_SETUP_LOG"
TARGET="$WORKDIR/dev-repo"
rm -rf "$TARGET"
set +e
out=$(run_wizard dev-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility public \
        --firebase dev --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "firebase=dev happy path completes (rc=0)" \
  || fail "firebase=dev failed; rc=$ec; out: $out"
n=$(grep -c "^firebase projects:create " "$SHIM_LOG" || true)
[ "$n" -eq 1 ] \
  && pass "firebase=dev triggers exactly 1 projects:create" \
  || fail "firebase=dev expected 1 projects:create, got $n; log: $(grep '^firebase ' "$SHIM_LOG")"
grep -qF "firebase projects:create dev-repo-dev --display-name dev-repo (dev)" "$SHIM_LOG" \
  && pass "firebase=dev creates 'dev-repo-dev' project with display name" \
  || fail "firebase=dev wrong project ID / display name; log: $(grep projects:create "$SHIM_LOG")"
# op-firebase-setup should have been invoked once per env.
[ -s "$OP_FB_SETUP_LOG" ] \
  && pass "op-firebase-setup invoked for dev env" \
  || fail "op-firebase-setup not invoked: $(cat "$OP_FB_SETUP_LOG" 2>/dev/null)"

# ========================================================================
# Case 3: firebase=dev+prod → exactly 2 projects:create calls.
# ========================================================================
: >"$SHIM_LOG"; : >"$OP_FB_SETUP_LOG"
TARGET="$WORKDIR/devprod-repo"
rm -rf "$TARGET"
set +e
out=$(run_wizard devprod-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility public \
        --firebase dev+prod --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "firebase=dev+prod happy path completes (rc=0)" \
  || fail "firebase=dev+prod failed; rc=$ec; out: $out"
n=$(grep -c "^firebase projects:create " "$SHIM_LOG" || true)
[ "$n" -eq 2 ] \
  && pass "firebase=dev+prod triggers exactly 2 projects:create" \
  || fail "firebase=dev+prod expected 2 projects:create, got $n"
grep -qF "firebase projects:create devprod-repo-dev " "$SHIM_LOG" \
  && pass "firebase=dev+prod creates dev project" \
  || fail "no devprod-repo-dev"
grep -qF "firebase projects:create devprod-repo-prod " "$SHIM_LOG" \
  && pass "firebase=dev+prod creates prod project" \
  || fail "no devprod-repo-prod"

# ========================================================================
# Case 4: visibility=public → no yq flip + no .coderabbit.yml delete.
# (already exercised in case 1; assert positively here.)
# ========================================================================
TARGET="$WORKDIR/none-repo"
# Verify the rsync'd files are present (no flip happened).
[ -f "$TARGET/.coderabbit.yml" ] \
  && pass "public visibility: .coderabbit.yml preserved" \
  || fail "public visibility: .coderabbit.yml was deleted ($TARGET/.coderabbit.yml absent)"
if [ -f "$TARGET/.github/review-policy.yml" ]; then
  if grep -q "enabled: true" "$TARGET/.github/review-policy.yml"; then
    pass "public visibility: coderabbit.enabled stayed true"
  else
    fail "public visibility: coderabbit.enabled NOT true; file: $(cat "$TARGET/.github/review-policy.yml")"
  fi
else
  fail "public visibility: review-policy.yml missing entirely at $TARGET/.github/"
fi

# ========================================================================
# Case 5: visibility=private → yq flip + delete + commit + push.
# ========================================================================
: >"$SHIM_LOG"; : >"$OP_FB_SETUP_LOG"
TARGET="$WORKDIR/priv-repo"
rm -rf "$TARGET"
set +e
out=$(run_wizard priv-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "visibility=private happy path completes (rc=0)" \
  || fail "visibility=private failed; rc=$ec; out: $out"
# yq flip happened — file should now show enabled: false.
if [ -f "$TARGET/.github/review-policy.yml" ]; then
  if grep -q "enabled: false" "$TARGET/.github/review-policy.yml"; then
    pass "private visibility: coderabbit.enabled flipped to false"
  else
    fail "private visibility: yq flip did not stick; file: $(cat "$TARGET/.github/review-policy.yml")"
  fi
else
  fail "private visibility: review-policy.yml missing"
fi
# .coderabbit.yml deleted.
if [ ! -f "$TARGET/.coderabbit.yml" ]; then
  pass "private visibility: .coderabbit.yml deleted"
else
  fail "private visibility: .coderabbit.yml still present"
fi
# Commit recorded in git log. Use a $(...) capture rather than a pipe
# to grep — the `cmd | grep -q` pattern races with `set -o pipefail`
# at the file-top because grep -q closes the pipe on first match,
# SIGPIPE'ing git log and propagating rc=141 through the pipeline
# even when the match was found (verified empirically on this fixture).
_git_log_out=$(git -C "$TARGET" log --oneline 2>/dev/null)
case "$_git_log_out" in
  *"disable CodeRabbit"*)
    pass "private visibility: commit 'disable CodeRabbit' recorded in git log"
    ;;
  *)
    fail "private visibility: commit not found; git log: $_git_log_out"
    ;;
esac
# Push: under BOOTSTRAP_SKIP_REMOTE_PUSH=1 (set by the test runner so
# test fixtures don't need a real bare remote), the stage logs a
# skip-of-push message instead of running `git push origin main`.
# Verify the skip-message path fired — that's the test-mode signal
# the push step ran (just short-circuited the network call).
echo "$out" | grep -q "BOOTSTRAP_SKIP_REMOTE_PUSH=1 — skipping git push origin main" \
  && pass "private visibility: push step ran (BOOTSTRAP_SKIP_REMOTE_PUSH=1 short-circuits the network call)" \
  || fail "private visibility: push step did not log the skip message; out: $out"

# ========================================================================
# Case 5a/5b/5c: visibility=private with one or both CodeRabbit files
# absent — regression for the round-1 Codex P1 finding (PR #248) that
# `git add --all .github/review-policy.yml .coderabbit.yml` exits 128
# when either pathspec doesn't match. The fix gates the add list to
# only-existing-or-tracked paths; the stage must NOT hard-fail when
# one or both files are missing.
#
# We invoke the disable-for-private function directly rather than
# round-tripping through the full wizard — that keeps the regression
# narrowly focused on the staging logic at the heart of the finding.
# ========================================================================
# Source helpers + the stage module so we can call the internal
# function. Use a subshell so set -euo pipefail interactions don't
# bleed into the rest of this test file.
(
  set -euo pipefail
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_LOG_FILE="$WORKDIR/case5x.bootstrap-log"
  BOOTSTRAP_STATE_FILE="$WORKDIR/case5x.bootstrap-state"
  export BOOTSTRAP_DRY_RUN BOOTSTRAP_LOG_FILE BOOTSTRAP_STATE_FILE
  # shellcheck source=/dev/null
  . "$ROOT/scripts/bootstrap/_lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/bootstrap/firebase-and-codereview.sh"

  # Build a target repo with policy file but NO .coderabbit.yml.
  T5a="$WORKDIR/case5a-policy-only"
  mkdir -p "$T5a/.github"
  cat >"$T5a/.github/review-policy.yml" <<'YAML'
external_review_threshold: 300
coderabbit:
  enabled: true
YAML
  git -C "$T5a" init -q
  git -C "$T5a" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
  git -C "$T5a" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m seed

  BOOTSTRAP_AUTHOR_NAME=t BOOTSTRAP_AUTHOR_EMAIL=t@t \
    BOOTSTRAP_SKIP_REMOTE_PUSH=1 \
    bootstrap::_coderabbit_disable_for_private "$T5a"
) 2>"$WORKDIR/case5a.err"
rc5a=$?
if [ "$rc5a" -eq 0 ]; then
  pass "case 5a: disable-for-private succeeds when .coderabbit.yml is absent"
else
  fail "case 5a: hard-failed when .coderabbit.yml was absent (rc=$rc5a); stderr: $(cat "$WORKDIR/case5a.err")"
fi
# Verify the commit landed AND only the policy file is in it (no
# spurious pathspec error before commit).
# Capture-and-case pattern avoids the `set -o pipefail` race where
# grep -q closes the pipe on first match, SIGPIPE'ing git log and
# propagating rc=141. (Same workaround as the case-5 commit check.)
_5a_log=$(git -C "$WORKDIR/case5a-policy-only" log --oneline 2>/dev/null)
case "$_5a_log" in
  *"disable CodeRabbit"*)
    pass "case 5a: 'disable CodeRabbit' commit recorded with only review-policy.yml present" ;;
  *)
    fail "case 5a: no disable-CodeRabbit commit; log: $_5a_log" ;;
esac

# 5b: .coderabbit.yml present but NO .github/review-policy.yml.
(
  set -euo pipefail
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_LOG_FILE="$WORKDIR/case5b.bootstrap-log"
  BOOTSTRAP_STATE_FILE="$WORKDIR/case5b.bootstrap-state"
  export BOOTSTRAP_DRY_RUN BOOTSTRAP_LOG_FILE BOOTSTRAP_STATE_FILE
  # shellcheck source=/dev/null
  . "$ROOT/scripts/bootstrap/_lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/bootstrap/firebase-and-codereview.sh"

  T5b="$WORKDIR/case5b-coderabbit-only"
  mkdir -p "$T5b"
  echo "language: en-US" >"$T5b/.coderabbit.yml"
  git -C "$T5b" init -q
  git -C "$T5b" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
  git -C "$T5b" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m seed

  BOOTSTRAP_AUTHOR_NAME=t BOOTSTRAP_AUTHOR_EMAIL=t@t \
    BOOTSTRAP_SKIP_REMOTE_PUSH=1 \
    bootstrap::_coderabbit_disable_for_private "$T5b"
) 2>"$WORKDIR/case5b.err"
rc5b=$?
if [ "$rc5b" -eq 0 ]; then
  pass "case 5b: disable-for-private succeeds when review-policy.yml is absent"
else
  fail "case 5b: hard-failed when review-policy.yml was absent (rc=$rc5b); stderr: $(cat "$WORKDIR/case5b.err")"
fi
if [ ! -f "$WORKDIR/case5b-coderabbit-only/.coderabbit.yml" ]; then
  pass "case 5b: .coderabbit.yml deleted as expected"
else
  fail "case 5b: .coderabbit.yml not deleted"
fi
_5b_log=$(git -C "$WORKDIR/case5b-coderabbit-only" log --oneline 2>/dev/null)
case "$_5b_log" in
  *"disable CodeRabbit"*)
    pass "case 5b: 'disable CodeRabbit' commit recorded with only .coderabbit.yml present" ;;
  *)
    fail "case 5b: no disable-CodeRabbit commit; log: $_5b_log" ;;
esac

# 5c: both files absent — early return, no commit, exit 0 (already
# covered by the touched_any=0 branch but assert explicitly so
# regressions in either branch are caught).
(
  set -euo pipefail
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_LOG_FILE="$WORKDIR/case5c.bootstrap-log"
  BOOTSTRAP_STATE_FILE="$WORKDIR/case5c.bootstrap-state"
  export BOOTSTRAP_DRY_RUN BOOTSTRAP_LOG_FILE BOOTSTRAP_STATE_FILE
  # shellcheck source=/dev/null
  . "$ROOT/scripts/bootstrap/_lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/bootstrap/firebase-and-codereview.sh"

  T5c="$WORKDIR/case5c-both-absent"
  mkdir -p "$T5c"
  echo "x" >"$T5c/README.md"
  git -C "$T5c" init -q
  git -C "$T5c" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
  git -C "$T5c" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m seed

  BOOTSTRAP_AUTHOR_NAME=t BOOTSTRAP_AUTHOR_EMAIL=t@t \
    BOOTSTRAP_SKIP_REMOTE_PUSH=1 \
    bootstrap::_coderabbit_disable_for_private "$T5c"
) 2>"$WORKDIR/case5c.err"
rc5c=$?
if [ "$rc5c" -eq 0 ]; then
  pass "case 5c: disable-for-private exits 0 when both files absent"
else
  fail "case 5c: hard-failed when both files absent (rc=$rc5c); stderr: $(cat "$WORKDIR/case5c.err")"
fi
_5c_log=$(git -C "$WORKDIR/case5c-both-absent" log --oneline 2>/dev/null)
case "$_5c_log" in
  *"disable CodeRabbit"*)
    fail "case 5c: spurious disable-CodeRabbit commit (both files absent — nothing to do)" ;;
  *)
    pass "case 5c: no commit when both files absent (correct no-op)" ;;
esac

# ========================================================================
# Case 6: codex_app=n → "NOT requested" log + no install URLs.
# ========================================================================
: >"$SHIM_LOG"
TARGET="$WORKDIR/codexn-repo"
rm -rf "$TARGET"
set +e
out=$(run_wizard codexn-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility public \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "codex_app=n run completes (rc=0)" \
  || fail "codex_app=n failed; rc=$ec; out: $out"
echo "$out" | grep -q "Codex App: NOT requested" \
  && pass "codex_app=n logs 'NOT requested' message" \
  || fail "codex_app=n missing 'NOT requested' log; got: $out"
# None of the Codex install URLs should appear in stdout when codex_app=n.
if echo "$out" | grep -q "github.com/apps/chatgpt-codex-connector"; then
  fail "codex_app=n leaked Codex install URL"
else
  pass "codex_app=n suppresses Codex install URLs"
fi

# ========================================================================
# Case 7: codex_app=y → all 3 install URLs printed.
# ========================================================================
: >"$SHIM_LOG"
TARGET="$WORKDIR/codexy-repo"
rm -rf "$TARGET"
set +e
out=$(run_wizard codexy-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility public \
        --firebase none --codex-app y --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "codex_app=y run completes (rc=0)" \
  || fail "codex_app=y failed; rc=$ec; out: $out"
echo "$out" | grep -q "github.com/apps/chatgpt-codex-connector" \
  && pass "codex_app=y prints App install URL" \
  || fail "codex_app=y missing App install URL; got: $out"
echo "$out" | grep -q "chatgpt.com/codex/cloud/settings/code-review" \
  && pass "codex_app=y prints code-review settings URL" \
  || fail "codex_app=y missing code-review settings URL"
echo "$out" | grep -q "chatgpt.com/codex/cloud/settings/environments" \
  && pass "codex_app=y prints environments settings URL" \
  || fail "codex_app=y missing environments URL"

# ========================================================================
# Case 8: State file records firebase-and-codereview on happy path.
# (use the priv-repo target from case 5)
# ========================================================================
if [ -f "$WORKDIR/priv-repo/.bootstrap-state" ] \
   && grep -q "^firebase-and-codereview\$" "$WORKDIR/priv-repo/.bootstrap-state"; then
  pass "state file records firebase-and-codereview on happy path"
else
  fail "state file missing firebase-and-codereview entry: $(cat "$WORKDIR/priv-repo/.bootstrap-state" 2>/dev/null)"
fi

# ========================================================================
# Case 9: SHIM_EXIT_FIREBASE=1 → stage fails closed, no state entry.
# ========================================================================
: >"$SHIM_LOG"; : >"$OP_FB_SETUP_LOG"
TARGET="$WORKDIR/firefail-repo"
rm -rf "$TARGET"
set +e
out=$(SHIM_EXIT_FIREBASE=1 run_wizard firefail-repo \
        --target-dir "$TARGET" \
        --description "d" --visibility public \
        --firebase dev --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && pass "SHIM_EXIT_FIREBASE=1: stage fails closed (rc=$ec)" \
  || fail "stage should fail when firebase create errors; rc=$ec"
if [ -f "$TARGET/.bootstrap-state" ] && grep -q "^firebase-and-codereview\$" "$TARGET/.bootstrap-state"; then
  fail "firebase-and-codereview recorded despite firebase failure"
else
  pass "firebase-and-codereview NOT recorded when firebase fails (resume can retry)"
fi

# ========================================================================
# Case 10: Dry-run produces a plan without invoking firebase / gh.
# ========================================================================
: >"$SHIM_LOG"; : >"$OP_FB_SETUP_LOG"
TARGET="$WORKDIR/dry-repo"
rm -rf "$TARGET"
set +e
dry_out=$(run_wizard dry-repo \
            --target-dir "$TARGET" \
            --description "d" --visibility private \
            --firebase dev+prod --codex-app y --project new --dry-run 2>&1)
dry_ec=$?
set -e
[ "$dry_ec" -eq 0 ] \
  && pass "stage D --dry-run exits 0" \
  || fail "dry-run failed: rc=$dry_ec, out: $dry_out"
# Dry-run must NOT actually invoke firebase or gh.
if grep -q "^firebase " "$SHIM_LOG"; then
  fail "dry-run invoked firebase shim ($(grep -c '^firebase ' "$SHIM_LOG") calls); should be 0"
else
  pass "dry-run did not invoke firebase (bootstrap::run honors --dry-run)"
fi
# op-firebase-setup is also a real script (not via the shim) but it
# also goes through bootstrap::run. Verify it wasn't invoked.
if [ -s "$OP_FB_SETUP_LOG" ]; then
  fail "dry-run invoked op-firebase-setup ($(wc -l <"$OP_FB_SETUP_LOG") times); should be 0"
else
  pass "dry-run did not invoke op-firebase-setup"
fi
# Plan output should mention DRY-RUN tags for stage D actions.
echo "$dry_out" | grep -q "DRY-RUN.*firebase projects:create" \
  && pass "dry-run plan includes firebase projects:create action" \
  || fail "dry-run plan missing firebase projects:create; got: $dry_out"
echo "$dry_out" | grep -q "DRY-RUN.*yq.*coderabbit.enabled" \
  && pass "dry-run plan includes yq coderabbit flip action" \
  || fail "dry-run plan missing yq coderabbit flip; got: $dry_out"

# --- summary --------------------------------------------------------------
echo
echo "test_bootstrap_firebase_and_codereview: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
