#!/usr/bin/env bash
# tests/test_bootstrap_board_and_summary.sh
#
# Validates scripts/bootstrap/board-and-summary.sh (sub-E / #207).
#
# Strategy: a PATH-shimmed `gh` records every invocation to a log file
# and returns canned exit codes. For `gh project create --format json`
# the shim emits a valid JSON response so the stage's number-parsing
# logic can be exercised end-to-end without contacting GitHub.
#
# Assertions cover:
#   1. `--skip-board` skips the Project v2 board sub-step entirely
#      (zero `gh project` invocations) while the rest of the stage
#      still runs (scaffolds + summary).
#   2. `--project new` path creates the board, configures the Status
#      single-select field, and sets the readme.
#   3. `--project 7` path attaches to existing #7 — no create, no
#      field-create, no readme write.
#   4. Empty PRD / spec / plan scaffolds are created at the right
#      paths with the documented placeholder text.
#   5. Stage records completion in the state file.
#   6. Dry-run produces a plan without invoking `gh project`.
#   7. Summary block contains all sections (REPO/PROJECT/LOCAL DIR,
#      DONE, SKIPPED, WARNINGS, NEXT STEPS) — on stdout AND on
#      .bootstrap-log.
#   8. Summary reflects state-file completions accurately: when only
#      template-mirror + github-infra are pre-seeded, those appear in
#      DONE; firebase + board-and-summary do not.
#
# Requires: bash, rsync (for sub-B in the chain), yq (preflight req).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-new-repo.sh"

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

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-board-summary.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- build fixture mergepath ------------------------------------------------
FAKE_MP="$WORKDIR/fake-mp"
mkdir -p "$FAKE_MP"/{scripts/bootstrap,scripts/ci,scripts/sync,.github/workflows,docs/agents,tests}
echo "# mergepath" >"$FAKE_MP/README.md"
echo "Mergepath brand" >"$FAKE_MP/BRAND.md"
echo "ai ctx" >"$FAKE_MP/.ai_context.md"
echo "overview" >"$FAKE_MP/docs/agents/repository-overview.md"
# #780: the mirror stage VERIFIES that every `class: canonical` agent doc
# landed in the new repo, and that AGENTS.md reads the shared operating rules
# before the local overlay. Seed the canonical docs and a conforming index so
# this fixture exercises the real bootstrap path instead of tripping the guard.
echo "decision records" >"$FAKE_MP/docs/agents/decision-records.md"
echo "shared rules" >"$FAKE_MP/docs/agents/shared-operating-rules.md"
echo "worktree placement" >"$FAKE_MP/docs/agents/worktree-placement.md"
echo "local overlay" >"$FAKE_MP/docs/agents/operating-rules.md"
cat >"$FAKE_MP/.mergepath-sync.yml" <<'EOF'
version: 1
doc_ownership:
  - path: docs/agents/decision-records.md
    class: canonical
  - path: docs/agents/shared-operating-rules.md
    class: canonical
  - path: docs/agents/worktree-placement.md
    class: canonical
  - path: docs/agents/bootstrap-runbook.md
    class: hub-only
EOF
cat >"$FAKE_MP/AGENTS.md" <<'AGENTSEOF'
# Agent Instructions

1. **[Repository Overview](docs/agents/repository-overview.md)**
2. **[Shared Agent Operating Rules](docs/agents/shared-operating-rules.md)**
3. **[Agent Operating Rules](docs/agents/operating-rules.md)**
4. **[Worktree Placement](docs/agents/worktree-placement.md)**
AGENTSEOF
cat >"$FAKE_MP/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
extra_top_level_dirs: [mergepath, packaging]
EOF
echo "Security" >"$FAKE_MP/SECURITY.md"

# Copy real bootstrap script + stage modules.
cp "$ROOT/scripts/bootstrap/_lib.sh"                  "$FAKE_MP/scripts/bootstrap/_lib.sh"
cp "$ROOT/scripts/bootstrap/substitute.sh"            "$FAKE_MP/scripts/bootstrap/substitute.sh"
cp "$ROOT/scripts/bootstrap/template-mirror.sh"       "$FAKE_MP/scripts/bootstrap/template-mirror.sh"
cp "$ROOT/scripts/bootstrap/github-infra.sh"          "$FAKE_MP/scripts/bootstrap/github-infra.sh"
cp "$ROOT/scripts/bootstrap/firebase-and-codereview.sh" "$FAKE_MP/scripts/bootstrap/firebase-and-codereview.sh"
cp "$ROOT/scripts/bootstrap/board-and-summary.sh"     "$FAKE_MP/scripts/bootstrap/board-and-summary.sh"
cp "$ROOT/scripts/bootstrap-new-repo.sh"              "$FAKE_MP/scripts/bootstrap-new-repo.sh"
git -C "$FAKE_MP" init -q
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture"

# --- gh PATH shim -----------------------------------------------------------
# Records every invocation to $SHIM_LOG. For `gh project create
# ... --format json` it emits a valid JSON document so the stage's
# `.number` parse exercises the live-path code (not just the dry-run
# branch).
SHIM_DIR="$WORKDIR/shim-bin"
SHIM_LOG="$WORKDIR/gh-shim.log"
mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/gh" <<'SHIM_EOF'
#!/usr/bin/env bash
# gh PATH-shim used by tests/test_bootstrap_board_and_summary.sh.

LOG=${SHIM_LOG:?SHIM_LOG not set}
echo "gh $*" >>"$LOG"

case "$1" in
  project)
    case "$2" in
      create)
        # The stage's live path captures stdout to a tmpfile then
        # parses `.number`. Emit a canned JSON response with
        # number=99 so the parse step has something to find.
        echo '{"id":"PVT_kw","number":99,"title":"shim-project"}'
        exit "${SHIM_EXIT_PROJECT_CREATE:-0}"
        ;;
      *) exit 0 ;;
    esac
    ;;
  repo)
    # Stage C creates the remote and then pushes separately (#790), so
    # the shim has to leave behind an `origin` the real `git push` can
    # reach: a bare repo beside the shim log.
    if [ "$2" = "create" ]; then
      remote_root="$(dirname "$LOG")/remotes"
      src=""
      for arg in "$@"; do
        case "$arg" in --source=*) src="${arg#--source=}" ;; esac
      done
      bare="$remote_root/${3##*/}.git"
      mkdir -p "$remote_root"
      git init -q --bare "$bare" 2>/dev/null
      if [ -n "$src" ] && [ -d "$src/.git" ]; then
        git -C "$src" remote remove origin >/dev/null 2>&1 || true
        git -C "$src" remote add origin "$bare"
      fi
    fi
    exit 0
    ;;
  label|api|secret|pr)
    if [ "$1" = "secret" ] && [ "$2" = "set" ]; then
      cat >/dev/null 2>&1 || true
    fi
    exit 0
    ;;
  config)
    # `gh config get -h github.com user` — used by the stage's
    # auth-switch-around to read the prior active account.
    echo "nathanpayne-claude"
    exit 0
    ;;
  auth) exit 0 ;;
  *)    exit 0 ;;
esac
SHIM_EOF
chmod +x "$SHIM_DIR/gh"

# Real PATH for everything else.
SHIM_PATH="$SHIM_DIR:/usr/bin:/bin"
for tool in bash yq git rsync sed awk grep mktemp tr cut tail head wc ls rm cat printf chmod find dirname basename jq; do
  src=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$src" ] && ln -sf "$src" "$SHIM_DIR/$tool"
done

run_wizard() {
  PATH="$SHIM_PATH" \
  SHIM_LOG="$SHIM_LOG" \
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
  "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: --project new — creates board, configures Status field, sets readme.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET1="$WORKDIR/new-board-repo"
rm -rf "$TARGET1"
set +e
out=$(run_wizard newboard-repo \
        --target-dir "$TARGET1" \
        --description "a test repo" \
        --visibility private --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "happy-path --project new completes (rc=0)" \
  || fail "wizard failed; rc=$ec; out: $out"

# `gh project create --owner nathanjohnpayne --title newboard-repo --format json`
grep -q "^gh project create --owner nathanjohnpayne --title newboard-repo --format json\$" "$SHIM_LOG" \
  && pass "gh project create invoked with --owner + --title + --format json" \
  || fail "gh project create flags wrong; log: $(grep '^gh project create' "$SHIM_LOG")"

# Status field-create with the canonical option set.
grep -q "^gh project field-create 99 --owner nathanjohnpayne --name Status --data-type SINGLE_SELECT --single-select-options Backlog,Ready,In progress,In review,Done\$" "$SHIM_LOG" \
  && pass "Status field-create invoked with canonical option set" \
  || fail "field-create flags wrong; log: $(grep 'field-create' "$SHIM_LOG")"

# Readme set via `gh project edit`.
grep -q "^gh project edit 99 --owner nathanjohnpayne --readme " "$SHIM_LOG" \
  && pass "project edit --readme invoked" \
  || fail "project edit --readme not invoked; log: $(grep 'project edit' "$SHIM_LOG")"

# Stage records completion.
[ -f "$TARGET1/.bootstrap-state" ] \
  && grep -q "^board-and-summary\$" "$TARGET1/.bootstrap-state" \
  && pass "board-and-summary stage recorded in state file" \
  || fail "state file missing board-and-summary entry: $(cat "$TARGET1/.bootstrap-state" 2>/dev/null)"

# Empty implementation-spec / plan scaffolds at the right paths. The spec
# stub references "implementation spec" and the plan stub references
# "Sprint 0 plan" — operator reading both should see distinct intents (CodeRabbit
# round-1 nit on #246: identical placeholder text masked the
# what-vs-how distinction).
SPEC_FILE="$TARGET1/specs/newboard-repo.md"
PLAN_FILE="$TARGET1/plans/newboard-repo-sprint-0.md"

if [ -f "$SPEC_FILE" ] && grep -q "TODO: write the implementation spec" "$SPEC_FILE"; then
  pass "specs/newboard-repo.md placeholder written"
else
  fail "specs file missing or wrong content"
fi

if [ -f "$PLAN_FILE" ] && grep -q "TODO: write the Sprint 0 plan" "$PLAN_FILE"; then
  pass "plans/newboard-repo-sprint-0.md placeholder written"
else
  fail "plans file missing or wrong content"
fi

# Distinctness assertion: the two placeholders must NOT be byte-
# identical. If a future refactor accidentally re-introduces the
# same text in both files, this test fails loudly. Skip silently
# if either file is missing — the per-file assertions above will
# have failed already.
if [ -f "$SPEC_FILE" ] && [ -f "$PLAN_FILE" ]; then
  if ! cmp -s "$SPEC_FILE" "$PLAN_FILE"; then
    pass "spec and plan placeholders are distinct"
  else
    fail "spec and plan placeholders are byte-identical"
  fi
fi

[ -f "$TARGET1/scripts/gh-projects/examples/newboard-repo/create-issues.sh" ] \
  && grep -q "issue-seeding skeleton" "$TARGET1/scripts/gh-projects/examples/newboard-repo/create-issues.sh" \
  && pass "scripts/gh-projects/examples/newboard-repo/create-issues.sh placeholder written" \
  || fail "create-issues.sh skeleton missing or wrong content"

[ -x "$TARGET1/scripts/gh-projects/examples/newboard-repo/create-issues.sh" ] \
  && pass "create-issues.sh is executable (chmod +x)" \
  || fail "create-issues.sh not executable"

# Summary block contains all required sections on stdout.
echo "$out" | grep -q "==> Bootstrap complete: nathanjohnpayne/newboard-repo" \
  && pass "summary block emits 'Bootstrap complete' header on stdout" \
  || fail "summary missing header on stdout"
echo "$out" | grep -q "^REPO: " \
  && pass "summary has REPO line" || fail "summary missing REPO line"
echo "$out" | grep -q "^PROJECT: " \
  && pass "summary has PROJECT line" || fail "summary missing PROJECT line"
echo "$out" | grep -q "^LOCAL DIR: " \
  && pass "summary has LOCAL DIR line" || fail "summary missing LOCAL DIR"
echo "$out" | grep -q "^DONE:" \
  && pass "summary has DONE section" || fail "summary missing DONE"
echo "$out" | grep -q "^SKIPPED:" \
  && pass "summary has SKIPPED section" || fail "summary missing SKIPPED"
echo "$out" | grep -q "^WARNINGS:" \
  && pass "summary has WARNINGS section" || fail "summary missing WARNINGS"
echo "$out" | grep -q "^CROSS-REPO LOOP UPDATE:" \
  && pass "summary has CROSS-REPO LOOP UPDATE section" \
  || fail "summary missing CROSS-REPO LOOP UPDATE"
echo "$out" | grep -q "^NEXT STEPS" \
  && pass "summary has NEXT STEPS section" || fail "summary missing NEXT STEPS"
# Regression guard for the gaycruisebingo gap (mergepath#741): the
# summary must steer the operator to enroll the repo as a
# .mergepath-sync.yml consumer, since the bootstrap does the one-time
# rsync + loop-doc registration but NOT ongoing sync enrollment.
echo "$out" | grep -q ".mergepath-sync.yml consumer" \
  && pass "summary reminds operator to enroll as a sync consumer (#741)" \
  || fail "summary missing .mergepath-sync.yml enrollment reminder (#741)"
echo "$out" | grep -q "docs/agents/bootstrap-runbook.md" \
  && pass "summary cross-links to docs/agents/bootstrap-runbook.md" \
  || fail "summary missing runbook cross-link"

# Summary appended to .bootstrap-log.
[ -f "$TARGET1/.bootstrap-log" ] \
  && grep -q "==> Bootstrap complete: nathanjohnpayne/newboard-repo" "$TARGET1/.bootstrap-log" \
  && pass "summary appended to .bootstrap-log" \
  || fail ".bootstrap-log missing summary"
grep -q "^DONE:" "$TARGET1/.bootstrap-log" \
  && grep -q "^NEXT STEPS" "$TARGET1/.bootstrap-log" \
  && pass ".bootstrap-log carries DONE + NEXT STEPS sections" \
  || fail ".bootstrap-log missing key sections"

# PROJECT URL in summary points at project #99 (from the shim's JSON).
echo "$out" | grep -q "https://github.com/users/nathanjohnpayne/projects/99" \
  && pass "summary PROJECT URL uses the parsed number (99)" \
  || fail "PROJECT URL did not reflect parsed number; got: $(echo "$out" | grep PROJECT)"

# ---------------------------------------------------------------------------
# Test 2: --project 7 — attaches to existing board, no create/field/readme.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET2="$WORKDIR/existing-board-repo"
rm -rf "$TARGET2"
set +e
out2=$(run_wizard exboard-repo \
         --target-dir "$TARGET2" \
         --description "d" --visibility private \
         --firebase none --codex-app n --project 7 2>&1)
ec2=$?
set -e
[ "$ec2" -eq 0 ] \
  && pass "--project 7 (reuse existing) completes (rc=0)" \
  || fail "wizard failed for --project 7; rc=$ec2; out: $out2"

# gh project create MUST NOT be invoked.
if grep -q "^gh project create" "$SHIM_LOG"; then
  fail "gh project create was invoked for --project 7 (should reuse existing)"
else
  pass "--project 7 skips gh project create (reuse path)"
fi
if grep -q "^gh project field-create" "$SHIM_LOG"; then
  fail "gh project field-create was invoked for --project 7 (should skip)"
else
  pass "--project 7 skips gh project field-create"
fi
if grep -q "^gh project edit" "$SHIM_LOG"; then
  fail "gh project edit was invoked for --project 7 (should skip readme)"
else
  pass "--project 7 skips gh project edit --readme"
fi
echo "$out2" | grep -q "reusing existing Project v2 #7" \
  && pass "--project 7 logs the reuse decision" \
  || fail "--project 7 should log 'reusing existing Project v2 #7'; got: $out2"
# PROJECT URL in summary points at #7.
echo "$out2" | grep -q "https://github.com/users/nathanjohnpayne/projects/7" \
  && pass "summary PROJECT URL uses the reused number (7)" \
  || fail "PROJECT URL did not reflect reused number; got: $(echo "$out2" | grep PROJECT)"

# ---------------------------------------------------------------------------
# Test 3: --skip-board — zero gh project invocations; scaffolds + summary still ran.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET3="$WORKDIR/skip-board-repo"
rm -rf "$TARGET3"
set +e
out3=$(run_wizard skipboard-repo \
         --target-dir "$TARGET3" \
         --description "d" --visibility private \
         --firebase none --codex-app n --skip-board 2>&1)
ec3=$?
set -e
[ "$ec3" -eq 0 ] \
  && pass "--skip-board completes (rc=0)" \
  || fail "wizard failed for --skip-board; rc=$ec3; out: $out3"

if grep -q "^gh project" "$SHIM_LOG"; then
  fail "gh project invoked despite --skip-board"
else
  pass "--skip-board emits zero gh project invocations"
fi
# Scaffolds still written.
[ -f "$TARGET3/specs/skipboard-repo.md" ] \
  && pass "--skip-board still writes specs scaffold" \
  || fail "--skip-board should still write specs scaffold"
# Summary still emitted; PROJECT line says skipped.
echo "$out3" | grep -q "==> Bootstrap complete: " \
  && pass "--skip-board still emits summary" \
  || fail "--skip-board should still emit summary"
echo "$out3" | grep -q "PROJECT: *(skipped: --skip-board)" \
  && pass "--skip-board summary shows project skipped with reason" \
  || fail "summary PROJECT line missing skip reason; got: $(echo "$out3" | grep PROJECT)"

# ---------------------------------------------------------------------------
# Test 4: dry-run — no gh project invocations; plan tags + summary printed.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET4="$WORKDIR/dry-run-board"
rm -rf "$TARGET4"
set +e
out4=$(run_wizard dryboard-repo \
         --target-dir "$TARGET4" \
         --description "d" --visibility private \
         --firebase none --codex-app n --project new --dry-run 2>&1)
ec4=$?
set -e
[ "$ec4" -eq 0 ] \
  && pass "dry-run --project new completes (rc=0)" \
  || fail "dry-run failed; rc=$ec4; out: $out4"
if [ -s "$SHIM_LOG" ]; then
  fail "dry-run invoked gh shim ($(wc -l <"$SHIM_LOG") calls); should be 0"
else
  pass "dry-run did not invoke gh (bootstrap::run honors --dry-run)"
fi
echo "$out4" | grep -q "DRY-RUN" \
  && pass "dry-run output includes [DRY-RUN] tags" \
  || fail "dry-run missing [DRY-RUN] markers"
# Summary still printed (with the placeholder <N> for the project number).
echo "$out4" | grep -q "==> Bootstrap complete:" \
  && pass "dry-run still emits summary block" \
  || fail "dry-run should still emit summary"

# ---------------------------------------------------------------------------
# Test 5: BOOTSTRAP_INPUT_PROJECT=skip via env var — same effect as --skip-board.
# ---------------------------------------------------------------------------
# The wizard's CLI parser rejects --project skip (only "new" or digits),
# but the stage itself honors project=skip when set via env (e.g., in
# tests or by other wizard versions). We invoke the stage by setting
# BOOTSTRAP_INPUT_PROJECT directly. Easiest path: --skip-board OR
# inject via the wizard's flag parser tolerantly — drop --project and
# pass --skip-board which the stage normalizes internally. This test
# pins the env-var path: source the stage and call it directly with a
# minimal harness so the env-var check fires.
: >"$SHIM_LOG"
TARGET5="$WORKDIR/proj-skip-env"
rm -rf "$TARGET5"
mkdir -p "$TARGET5"
# Build a tiny harness shell. The stage relies on a few wizard globals
# being exported (TARGET_DIR, BOOTSTRAP_LOG_FILE, BOOTSTRAP_STATE_FILE,
# bootstrap_input). Reuse the wizard via env-var-only path:
set +e
out5=$(PATH="$SHIM_PATH" \
       SHIM_LOG="$SHIM_LOG" \
       BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
       BOOTSTRAP_SKIP_TOOL_CHECK=1 \
       BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
       BOOTSTRAP_AUTO_CONFIRM=1 \
       BOOTSTRAP_AUTO_PROMPT=skip \
       BOOTSTRAP_AUTHOR_NAME="test" \
       BOOTSTRAP_AUTHOR_EMAIL="t@t" \
       BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 \
       BOOTSTRAP_SKIP_INVITE_PAUSE=1 \
       BOOTSTRAP_REVIEWER_PAT_VALUE="x" \
       BOOTSTRAP_SKIP_STAGES=template-mirror,github-infra,firebase-and-codereview \
       BOOTSTRAP_INPUT_PROJECT=skip \
       "$SCRIPT" projskip-repo \
       --target-dir "$TARGET5" \
       --description d --visibility private \
       --firebase none --codex-app n 2>&1)
ec5=$?
set -e
# We injected BOOTSTRAP_INPUT_PROJECT=skip via env; the CLI parser would
# otherwise reject the literal "skip". The wizard reads
# bootstrap_input project from the env-exported var.
[ "$ec5" -eq 0 ] \
  && pass "BOOTSTRAP_INPUT_PROJECT=skip path completes (rc=0)" \
  || fail "env-var skip path failed; rc=$ec5; out: $out5"
if grep -q "^gh project" "$SHIM_LOG"; then
  fail "gh project invoked despite BOOTSTRAP_INPUT_PROJECT=skip"
else
  pass "BOOTSTRAP_INPUT_PROJECT=skip emits zero gh project invocations"
fi
echo "$out5" | grep -q "project board skipped (project=skip)" \
  && pass "stage logs project=skip reason" \
  || fail "stage should log 'project=skip' reason; got: $out5"

# ---------------------------------------------------------------------------
# Test 6: Summary reflects state-file completions accurately.
#
# Seed a state file containing only template-mirror + github-infra
# (i.e., earlier stages completed; firebase + board-and-summary did NOT
# run yet on a prior aborted run). Now run JUST the stage E via
# --resume firebase-and-codereview, which should still skip firebase
# (since it's already recorded by --resume), and verify the summary
# lists the seeded entries as DONE.
#
# Simpler: drive the wizard normally with all stages but check the
# DONE list against the actual recorded stages. The acceptance is
# that DONE only lists stages found in the state file at the time
# the summary runs.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET6="$WORKDIR/state-reflect"
rm -rf "$TARGET6"
mkdir -p "$TARGET6"
# Pre-seed state with the first two stages only. Run with --resume so
# the wizard skips them; the firebase + board-and-summary stages then
# run normally. The summary should list template-mirror, github-infra,
# AND firebase-and-codereview as DONE (since firebase ran fresh under
# this invocation), plus the board-and-summary itself.
cat >"$TARGET6/.bootstrap-state" <<'EOF'
template-mirror
github-infra
EOF
set +e
out6=$(run_wizard reflect-repo \
         --target-dir "$TARGET6" \
         --description d --visibility private --firebase none --codex-app n \
         --project new --resume 2>&1)
ec6=$?
set -e
[ "$ec6" -eq 0 ] \
  && pass "resume-from-state-seed completes (rc=0)" \
  || fail "resume-from-state-seed failed; rc=$ec6; out: $out6"

# Summary's DONE block must include all four stages now.
echo "$out6" | grep -q "Template mirror" \
  && pass "summary DONE lists template-mirror (from seeded state)" \
  || fail "summary should list template-mirror; got: $out6"
echo "$out6" | grep -q "GitHub repo created" \
  && pass "summary DONE lists github-infra (from seeded state)" \
  || fail "summary should list github-infra; got: $out6"

# Now exercise the "early-abort" scenario: state file lists ONLY B + C
# (no firebase, no board), then run JUST the board stage in isolation
# and verify firebase shows up in SKIPPED (not in state).
: >"$SHIM_LOG"
TARGET7="$WORKDIR/state-partial"
rm -rf "$TARGET7"
mkdir -p "$TARGET7"
cat >"$TARGET7/.bootstrap-state" <<'EOF'
template-mirror
github-infra
EOF
set +e
out7=$(PATH="$SHIM_PATH" \
       SHIM_LOG="$SHIM_LOG" \
       BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
       BOOTSTRAP_SKIP_TOOL_CHECK=1 \
       BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
       BOOTSTRAP_AUTO_CONFIRM=1 \
       BOOTSTRAP_AUTO_PROMPT=skip \
       BOOTSTRAP_AUTHOR_NAME="test" \
       BOOTSTRAP_AUTHOR_EMAIL="t@t" \
       BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 \
       BOOTSTRAP_SKIP_INVITE_PAUSE=1 \
       BOOTSTRAP_REVIEWER_PAT_VALUE="x" \
       BOOTSTRAP_SKIP_STAGES=template-mirror,github-infra,firebase-and-codereview \
       "$SCRIPT" partial-repo \
       --target-dir "$TARGET7" \
       --description d --visibility private --firebase none --codex-app n \
       --project new 2>&1)
ec7=$?
set -e
[ "$ec7" -eq 0 ] \
  && pass "stage-only invocation (B/C in state, D skipped) completes" \
  || fail "stage-only invocation failed; rc=$ec7; out: $out7"
# firebase NOT in state file → SKIPPED section.
echo "$out7" | grep -q "Firebase + CodeRabbit + Codex posture (not in state file)" \
  && pass "summary SKIPPED reflects firebase NOT in state file" \
  || fail "summary should flag firebase-and-codereview as skipped (not in state); got: $out7"

# ---------------------------------------------------------------------------
# Test 7: WARNINGS block splits outstanding failures from resolved ones.
#
# The `${BOOTSTRAP_STATE_FILE}.warnings` sidecar carries two kinds of
# record: still-outstanding failures, and ones a later attempt in the
# same bootstrap fixed (rewritten in place by github-infra.sh with the
# `RESOLVED: ` marker — #761). A resolved record must not read as
# outstanding work, and must not vanish either. Classification is by
# POSITIVE match on the marker, so an unrecognized line shape stays a
# failure.
#
# Drive the renderer directly with a hand-seeded sidecar covering all
# three shapes: keyed outstanding, keyed resolved, unkeyed outstanding.
# ---------------------------------------------------------------------------
TARGET8="$WORKDIR/warn-split"
rm -rf "$TARGET8"
mkdir -p "$TARGET8"
cat >"$TARGET8/.bootstrap-state" <<'EOF'
template-mirror
github-infra
EOF
printf '@reviewer-assignment-token\tRESOLVED: token provisioning failed earlier and was fixed on a later attempt\n' \
  >"$TARGET8/.bootstrap-state.warnings"
printf '@some-other-key\tsomething else is still broken\n' \
  >>"$TARGET8/.bootstrap-state.warnings"
printf 'an unkeyed recorded failure\n' \
  >>"$TARGET8/.bootstrap-state.warnings"
set +e
out8=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET8"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/board-and-summary.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_INPUT_FIREBASE=none
  bootstrap::_print_summary "nathanjohnpayne/warnsplit-repo" "$TARGET" "private" "" "project=skip"
' 2>&1)
ec8=$?
set -e
[ "$ec8" -eq 0 ] \
  && pass "summary renders a mixed outstanding/resolved warnings sidecar (rc=0)" \
  || fail "mixed-sidecar summary failed; rc=$ec8; out: $out8"
echo "$out8" | grep -qF "  !! - something else is still broken" \
  && pass "keyed outstanding failure stays in RECORDED FAILURES" \
  || fail "keyed outstanding failure missing from RECORDED FAILURES; out: $out8"
echo "$out8" | grep -qF "  !! - an unkeyed recorded failure" \
  && pass "unkeyed record stays in RECORDED FAILURES (fail-closed default)" \
  || fail "unkeyed record missing from RECORDED FAILURES; out: $out8"
echo "$out8" | grep -qF "  ok - token provisioning failed earlier and was fixed on a later attempt" \
  && pass "resolved record renders under RESOLVED with the marker stripped" \
  || fail "resolved record not rendered under RESOLVED; out: $out8"
echo "$out8" | grep -qF "  !! - RESOLVED:" \
  && fail "resolved record leaked into RECORDED FAILURES; out: $out8" \
  || pass "resolved record does not appear as an outstanding failure"

# A sidecar holding ONLY resolved records must print the RESOLVED block
# and NO RECORDED FAILURES header — nothing is outstanding.
TARGET9="$WORKDIR/warn-all-resolved"
rm -rf "$TARGET9"
mkdir -p "$TARGET9"
cp "$TARGET8/.bootstrap-state" "$TARGET9/.bootstrap-state"
printf '@reviewer-assignment-token\tRESOLVED: fixed on the retry\n' \
  >"$TARGET9/.bootstrap-state.warnings"
set +e
out9=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/board-and-summary.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_INPUT_FIREBASE=none
  bootstrap::_print_summary "nathanjohnpayne/allresolved-repo" "$TARGET" "private" "" "project=skip"
' 2>&1)
ec9=$?
set -e
[ "$ec9" -eq 0 ] \
  && pass "summary renders an all-resolved warnings sidecar (rc=0)" \
  || fail "all-resolved summary failed; rc=$ec9; out: $out9"
echo "$out9" | grep -q "RECORDED FAILURES" \
  && fail "all-resolved sidecar still printed a RECORDED FAILURES header; out: $out9" \
  || pass "all-resolved sidecar prints no RECORDED FAILURES header"
echo "$out9" | grep -qF "  ok - fixed on the retry" \
  && pass "all-resolved sidecar still surfaces the record under RESOLVED" \
  || fail "all-resolved sidecar dropped the record; out: $out9"

# ---------------------------------------------------------------------------
# Test 7b: only a KEYED record can be classified resolved (#781 item 3).
#
# bootstrap::_resolve_recorded_warning is the only producer of the
# RESOLVED: marker and it always writes "@<key><TAB>RESOLVED: …" — it
# exists to replace the keyed line it just read. bootstrap::record_warning
# persists an UNKEYED message verbatim, so an unkeyed record whose text
# merely starts with "RESOLVED: " is not a resolution record at all. When
# the renderer tested the message field alone, such a record was silently
# downgraded out of the one block that tells the operator a miss must be
# fixed before the first PR.
#
# Both directions are pinned: the unkeyed look-alike stays outstanding,
# and a genuinely keyed resolved record in the SAME sidecar is still
# downgraded (so the narrowing didn't just disable the RESOLVED block).
# ---------------------------------------------------------------------------
TARGET10="$WORKDIR/warn-unkeyed-lookalike"
rm -rf "$TARGET10"
mkdir -p "$TARGET10"
cp "$TARGET8/.bootstrap-state" "$TARGET10/.bootstrap-state"
printf 'RESOLVED: an unkeyed record that merely starts with the marker text\n' \
  >"$TARGET10/.bootstrap-state.warnings"
printf '@reviewer-assignment-token\tRESOLVED: a genuinely keyed resolution record\n' \
  >>"$TARGET10/.bootstrap-state.warnings"
set +e
out10=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET10"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/board-and-summary.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_INPUT_FIREBASE=none
  bootstrap::_print_summary "nathanjohnpayne/unkeyed-repo" "$TARGET" "private" "" "project=skip"
' 2>&1)
ec10=$?
set -e
[ "$ec10" -eq 0 ] \
  && pass "summary renders an unkeyed marker-lookalike sidecar (rc=0)" \
  || fail "unkeyed-lookalike summary failed; rc=$ec10; out: $out10"
echo "$out10" | grep -qF "  !! - RESOLVED: an unkeyed record that merely starts with the marker text" \
  && pass "unkeyed record starting with the marker stays in RECORDED FAILURES (#781 item 3)" \
  || fail "unkeyed marker-lookalike was misclassified as resolved; out: $out10"
echo "$out10" | grep -qF "  ok - an unkeyed record that merely starts with the marker text" \
  && fail "unkeyed marker-lookalike rendered under RESOLVED; out: $out10" \
  || pass "unkeyed marker-lookalike does not appear under RESOLVED"
echo "$out10" | grep -qF "  ok - a genuinely keyed resolution record" \
  && pass "a keyed resolution record in the same sidecar is still downgraded" \
  || fail "narrowing disabled the RESOLVED block for keyed records; out: $out10"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_bootstrap_board_and_summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
