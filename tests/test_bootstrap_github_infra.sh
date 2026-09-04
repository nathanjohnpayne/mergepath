#!/usr/bin/env bash
# tests/test_bootstrap_github_infra.sh
#
# Validates scripts/bootstrap/github-infra.sh (sub-C / #205).
#
# Strategy: a PATH-shimmed `gh` records every invocation to a log
# file and returns canned exit codes. The shim NEVER contacts the
# real GitHub API. The wizard then drives the stage end-to-end and
# we assert against the log:
#
#   1. `gh repo create` is invoked with the right flags (visibility,
#      description, source — and NOT --push, which is now its own
#      command under the same verified author credential).
#   2. All 19 canonical labels are seeded with --force (idempotency).
#   3. Reviewer invitations land via `gh api -X PUT` to the right
#      collaborator endpoint for each agent in BOOTSTRAP_INPUT_REVIEWERS.
#   4. REVIEWER_ASSIGNMENT_TOKEN provisioning uses the inline-PAT
#      path when BOOTSTRAP_REVIEWER_PAT_VALUE is set.
#   5. Stage failure propagates when `gh repo create` returns non-zero
#      (the state file must NOT carry a github-infra completion entry).
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

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-github-infra.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- build fixture mergepath ----------------------------------------------
FAKE_MP="$WORKDIR/fake-mp"
TARGET="$WORKDIR/new-repo"
mkdir -p "$FAKE_MP"/{scripts/bootstrap,scripts/ci,scripts/sync,.github/workflows,docs/agents,tests}
echo "# mergepath" >"$FAKE_MP/README.md"
echo "Mergepath brand" >"$FAKE_MP/BRAND.md"
echo "ai ctx" >"$FAKE_MP/.ai_context.md"
echo "overview" >"$FAKE_MP/docs/agents/repository-overview.md"
# #780: the mirror stage now VERIFIES that every `class: canonical` agent doc
# landed in the new repo, and that AGENTS.md reads the shared operating rules
# before the local overlay. Seed both docs and a conforming index so this
# fixture exercises the real bootstrap path instead of tripping the guard.
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

## Sections

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

# Copy real bootstrap script + stage modules
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

# --- gh PATH shim ----------------------------------------------------------
# Records every invocation to $SHIM_LOG. Returns 0 by default; tests
# can override per-subcommand exit via $SHIM_EXIT_<UPPERCASE-SUBCMD>=N.
SHIM_DIR="$WORKDIR/shim-bin"
SHIM_LOG="$WORKDIR/gh-shim.log"
mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/gh" <<'SHIM_EOF'
#!/usr/bin/env bash
# gh PATH-shim used by tests/test_bootstrap_github_infra.sh.
# Records every invocation to $SHIM_LOG.

LOG=${SHIM_LOG:?SHIM_LOG not set}
# One line per invocation: cmd1 cmd2 args...
echo "gh $*" >>"$LOG"

# Subcommand-conditional exit code. Per-subcommand env vars let
# tests dial in specific failures (e.g., SHIM_EXIT_REPO_CREATE=1).
case "$1" in
  repo)
    case "$2" in
      create)
        rc="${SHIM_EXIT_REPO_CREATE:-0}"
        if [ "$rc" = "0" ]; then
          # Emulate the part of `gh repo create --source=<dir>` the stage
          # depends on: the repository now exists and the local tree has
          # an `origin` pointing at it. The stand-in remote is a bare repo
          # beside the shim log, which makes the stage's own `git push` a
          # REAL push rather than something else to fake.
          remote_root="$(dirname "$LOG")/remotes"
          full_name="$3"
          src=""
          for arg in "$@"; do
            case "$arg" in --source=*) src="${arg#--source=}" ;; esac
          done
          bare="$remote_root/${full_name##*/}.git"
          mkdir -p "$remote_root"
          # SHIM_PUSH_BROKEN=1 wires origin up WITHOUT creating the bare
          # repo behind it: the create succeeds and the push then fails,
          # exactly as a transient network / credential failure would.
          if [ "${SHIM_PUSH_BROKEN:-0}" != "1" ]; then
            git init -q --bare "$bare" 2>/dev/null
          fi
          if [ -n "$src" ] && [ -d "$src/.git" ]; then
            git -C "$src" remote remove origin >/dev/null 2>&1 || true
            git -C "$src" remote add origin "$bare"
          fi
        fi
        exit "$rc"
        ;;
      *) exit 0 ;;
    esac
    ;;
  label)
    # $3 is the label name for `gh label create <name> ...`.
    # GH_SHIM_FAIL_LABEL fails exactly ONE named label so a test can prove
    # the seed loop continues past it; SHIM_EXIT_LABEL keeps its existing
    # all-or-nothing meaning for the callers that already use it.
    if [ -n "${GH_SHIM_FAIL_LABEL:-}" ] && [ "${3:-}" = "$GH_SHIM_FAIL_LABEL" ]; then
      echo "gh: HTTP 422: Validation Failed (label create $3)" >&2
      exit 1
    fi
    exit "${SHIM_EXIT_LABEL:-0}"
    ;;
  api)
    exit "${SHIM_EXIT_API:-0}"
    ;;
  secret)
    # `gh secret set --body -` reads stdin; consume it so the
    # pipe doesn't break.
    if [ "$2" = "set" ]; then
      cat >/dev/null 2>&1 || true
    fi
    # A failing gh writes a diagnostic before it exits. Emitting one
    # here is what keeps the "the gh-reached branch persists no
    # capture" assertion honest: a silent shim would satisfy it with
    # an empty capture no matter what the branch does.
    if [ "${SHIM_EXIT_SECRET:-0}" != "0" ]; then
      echo "gh: HTTP 403: Resource not accessible by personal access token (secret set)" >&2
    fi
    exit "${SHIM_EXIT_SECRET:-0}"
    ;;
  config)
    # `gh config get -h github.com user` — return the active acct
    # used by stage B's switch-around tests. github-infra doesn't
    # use this, but other stages might be invoked in the same run.
    echo "nathanpayne-claude"
    exit 0
    ;;
  auth)
    # `gh auth switch -u X` — no-op shim.
    exit 0
    ;;
  pr)
    # Stage B's cross-repo loop may call gh pr create when anchors
    # exist (they don't in this fixture — so this is just defensive).
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SHIM_EOF
chmod +x "$SHIM_DIR/gh"

# --- run the wizard end-to-end with stages B + C exercising the shim ----
# Stage D (firebase-and-codereview) and E (board-and-summary) are
# still stubs and will run; their record_stage calls are fine.
SHIM_PATH="$SHIM_DIR:/usr/bin:/bin"
# Include yq + git + rsync from the real PATH (the shim only covers
# gh). We need bash 3.2+ on macOS to keep this portable.
for tool in bash yq git rsync sed awk grep mktemp tr cut tail head wc ls rm cat printf chmod find dirname basename; do
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
  BOOTSTRAP_SKIP_STAGES=board-and-summary \
  "$SCRIPT" "$@"
}

# --- happy path -----------------------------------------------------------
: >"$SHIM_LOG"
rm -rf "$TARGET"
set +e
out=$(run_wizard test-repo \
        --target-dir "$TARGET" \
        --description "a test repo" \
        --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e

[ "$ec" -eq 0 ] \
  && pass "happy-path live run completes (rc=0)" \
  || fail "wizard failed; rc=$ec; out: $out"

# --- assertion 1: gh repo create invoked correctly ---
# `--push` is deliberately NOT on the create: creation and push are
# separate commands so the create can be checkpointed the moment it
# succeeds and a failed push stays retryable (#790, assertion 18e).
grep -q "^gh repo create nathanjohnpayne/test-repo --private --description a test repo --source=$TARGET$" "$SHIM_LOG" \
  && pass "gh repo create invoked with --private + --source" \
  || fail "gh repo create flags wrong; log: $(grep '^gh repo create' "$SHIM_LOG")"
grep -q "^gh repo create .* --push" "$SHIM_LOG" \
  && fail "gh repo create still carries --push (create + push share one rc again); log: $(grep '^gh repo create' "$SHIM_LOG")" \
  || pass "gh repo create no longer bundles --push"

# --- assertion 1b: the bootstrap commit is pushed as its own step ---
echo "$out" | grep -q "push bootstrap commit to nathanjohnpayne/test-repo" \
  && pass "the bootstrap commit is pushed by a separate step" \
  || fail "no separate push step logged; out: $out"
# And it really pushed: the shim's stand-in remote has the commit.
[ -d "$WORKDIR/remotes/test-repo.git" ] \
  && git -C "$WORKDIR/remotes/test-repo.git" rev-parse --verify -q refs/heads/main >/dev/null \
  && pass "the bootstrap commit landed on the remote's main" \
  || fail "remote has no main after the push: $(git -C "$WORKDIR/remotes/test-repo.git" branch -a 2>&1)"

# --- assertion 2: all 19 labels seeded with --force ---
# Hard-coded on purpose: this is an INDEPENDENT assertion of the intended
# set, not a mirror of BOOTSTRAP_LABELS. Deriving it from the array would
# make the test pass trivially if the array were emptied or mis-parsed.
# The `size:` / `priority:` names carry a colon, which is exactly what the
# old `name:color:description` encoding could not express — a regression to
# ':' would seed a label named `size` and fail these entries.
expected_labels=(needs-external-review needs-human-review policy-violation human-hold human-action decision-needed agent-action phase-0 phase-1 phase-2 phase-3 phase-4 size:S size:M size:L priority:critical priority:high priority:normal priority:low)
seeded=0
for label in "${expected_labels[@]}"; do
  if grep -qE "^gh label create $label .* --force\$" "$SHIM_LOG"; then
    seeded=$((seeded + 1))
  else
    fail "label '$label' not seeded with --force; log: $(grep "label create $label" "$SHIM_LOG")"
  fi
done
[ "$seeded" -eq 19 ] \
  && pass "all 19 canonical labels seeded with --force" \
  || fail "expected 19 labels, got $seeded"

# --- assertion 2b: the malformed-spec guard fails CLOSED (Codex P2, #1182) ---
# The parse uses ${var%%|*} / ${var#*|}, which return the input UNCHANGED
# when the separator is absent. A one-separator entry therefore does not
# fail on its own — it aliases two fields onto one value:
# "future-label|abcdef" yields color=abcdef AND desc=abcdef, which passes
# a colour-only check and creates a label with its colour copied into its
# description. Drive the REAL _seed_labels so this asserts the shipped
# path, not a re-implementation of it.
#
# Writes to its OWN shim log: $SHIM_LOG still holds the happy-path run that
# the invite / secret-set assertions below read, and truncating it here
# would fail them from a distance.
GUARD_LOG="$WORKDIR/gh-shim-labelguard.log"
: >"$GUARD_LOG"
set +e
malformed_out=$(PATH="$SHIM_PATH" SHIM_LOG="$GUARD_LOG" bash -c '
  ROOT="'"$ROOT"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE=""
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  # One separator (the Codex case), none at all, a non-hex colour, and an
  # empty name / empty description — then one WELL-FORMED entry whose name
  # and description both carry colons, and one whose description carries
  # the separator itself, to prove the guard rejects only the bad ones.
  BOOTSTRAP_LABELS=(
    "future-label|abcdef"
    "no-separators-at-all"
    "bad-colour|zzzzzz|nope"
    "|abcdef|empty name"
    "empty-desc|abcdef|"
    "size:S|c2e0c6|Small: one or a few files."
    "piped|abcdef|desc|with|pipes"
  )
  bootstrap::_seed_labels "nathanjohnpayne/guard-repo"
' 2>&1)
set -e
for bad in future-label no-separators-at-all bad-colour empty-desc; do
  grep -q "^gh label create $bad " "$GUARD_LOG" \
    && fail "malformed spec '$bad' reached gh label create; log: $(cat "$GUARD_LOG")" \
    || pass "malformed spec '$bad' never reached gh label create"
done
printf '%s' "$malformed_out" | grep -q "future-label|abcdef" \
  && pass "the one-separator spec is named in a warning rather than silently dropped" \
  || fail "no warning named the one-separator spec; out: $malformed_out"
grep -q "^gh label create size:S --repo nathanjohnpayne/guard-repo --color c2e0c6 " "$GUARD_LOG" \
  && pass "a colon-bearing name still seeds with its own colour after the guard" \
  || fail "well-formed colon-bearing spec was rejected by the guard; log: $(cat "$GUARD_LOG")"
grep -q -- "--description desc|with|pipes --force$" "$GUARD_LOG" \
  && pass "a description containing the separator round-trips intact" \
  || fail "pipe-bearing description did not round-trip; log: $(cat "$GUARD_LOG")"
[ "$(grep -c '^gh label create ' "$GUARD_LOG")" -eq 2 ] \
  && pass "exactly the 2 well-formed specs were seeded (5 malformed skipped, none fatal)" \
  || fail "expected 2 seeded labels, got $(grep -c '^gh label create ' "$GUARD_LOG"); log: $(cat "$GUARD_LOG")"

# --- assertion 2c: a failed label create is RECORDED, not just warned (#1182) ---
# bootstrap::warn writes to stderr only. A failed `gh label create` is
# non-fatal, so under warn the failure scrolled past while the stage
# summary still reported the full label count as done — the operator had
# no surviving signal that the set was short. record_warning persists to
# the warnings sidecar the summary reads. Assert the SIDECAR, because
# that is the property the summary depends on; asserting stderr would
# pass just as well under the old broken behaviour.
LBLFAIL_TARGET="$WORKDIR/label-failure-record"
rm -rf "$LBLFAIL_TARGET"; mkdir -p "$LBLFAIL_TARGET"
LBLFAIL_LOG="$WORKDIR/gh-shim-labelfail.log"
: >"$LBLFAIL_LOG"
set +e
lblfail_out=$(PATH="$SHIM_PATH" SHIM_LOG="$LBLFAIL_LOG" GH_SHIM_FAIL_LABEL="flaky-label" bash -c '
  ROOT="'"$ROOT"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="'"$LBLFAIL_TARGET"'/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  BOOTSTRAP_LABELS=(
    "flaky-label|abcdef|this one fails at the API"
    "good-label|c2e0c6|this one succeeds"
  )
  bootstrap::_seed_labels "nathanjohnpayne/labelfail-repo"
  echo "SEED_RC=$?"
' 2>&1)
set -e
printf '%s' "$lblfail_out" | grep -q "SEED_RC=0" \
  && pass "a single label failure stays non-fatal (the stage continues)" \
  || fail "label failure became fatal; out: $lblfail_out"
grep -q "^gh label create good-label " "$LBLFAIL_LOG" \
  && pass "the label after a failing one is still attempted" \
  || fail "a failing label aborted the remaining seeds; log: $(cat "$LBLFAIL_LOG")"
grep -q "flaky-label" "$LBLFAIL_TARGET/.bootstrap-state.warnings" 2>/dev/null \
  && pass "the failed label create is RECORDED in the warnings sidecar the summary reads" \
  || fail "failed label create left no record for the summary; sidecar: $(cat "$LBLFAIL_TARGET/.bootstrap-state.warnings" 2>/dev/null || echo '<absent>')"
grep -q "labelfail-repo" "$LBLFAIL_TARGET/.bootstrap-state.warnings" 2>/dev/null \
  && pass "the record names the repo the label failed on" \
  || fail "the record does not name the target repo; sidecar: $(cat "$LBLFAIL_TARGET/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 3: reviewer collaborator invites ---
for agent in claude cursor codex; do
  login="nathanpayne-$agent"
  if grep -qF "gh api -X PUT repos/nathanjohnpayne/test-repo/collaborators/$login -f permission=write" "$SHIM_LOG"; then
    pass "reviewer collaborator invite sent to $login"
  else
    fail "no invite for $login; log: $(grep collaborator "$SHIM_LOG")"
  fi
done

# --- assertion 4: REVIEWER_ASSIGNMENT_TOKEN secret set via inline PAT ---
# The `--body -` arg was removed in round 1 because gh treats it as
# a literal value, not a stdin signal — stdin is only consumed when
# --body is OMITTED entirely. Codex P1 on #239 caught this.
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/test-repo\$" "$SHIM_LOG" \
  && pass "REVIEWER_ASSIGNMENT_TOKEN secret set via stdin (no --body arg)" \
  || fail "REVIEWER_ASSIGNMENT_TOKEN secret-set not logged correctly; log: $(grep secret "$SHIM_LOG")"
# Regression guard: --body must NOT appear in the recorded secret-set
# command (would mean the bug regressed).
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN .* --body" "$SHIM_LOG" \
  && fail "secret set command carries --body (regression of Codex #239 P1 line 299)" \
  || pass "secret set command omits --body (Codex #239 P1 fixed)"

# --- assertion 5: stage records completion in state file ---
[ -f "$TARGET/.bootstrap-state" ] \
  && grep -q "^github-infra\$" "$TARGET/.bootstrap-state" \
  && pass "github-infra stage recorded in state file" \
  || fail "state file missing github-infra entry: $(cat "$TARGET/.bootstrap-state" 2>/dev/null)"

# --- assertion 6: dispatch ordering — template-mirror runs BEFORE github-infra ---
# Sub-B must complete first (it sets up the .git/ that sub-C pushes).
awk '
  /^template-mirror$/ { mirror = NR }
  /^github-infra$/    { infra  = NR }
  END {
    if (!mirror || !infra) { print "missing entries"; exit 1 }
    if (mirror > infra) { print "ordering wrong"; exit 1 }
  }
' "$TARGET/.bootstrap-state" \
  && pass "template-mirror recorded before github-infra in state file" \
  || fail "state-file ordering broken"

# --- assertion 7a: author-identity writes do not mutate gh auth state
# (#412). The live stage routes through token-verifying helpers; this
# test uses BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 so the gh shim sees the same
# commands directly, but no `gh auth switch` should ever be invoked.
# ---------------------------------------------------------------------------
auth_switches=$(grep -c "^gh auth switch -u" "$SHIM_LOG" || true)
[ "$auth_switches" -eq 0 ] \
  && pass "stage performs zero gh auth switches" \
  || fail "expected zero auth switches, got $auth_switches; log: $(grep 'auth switch' "$SHIM_LOG")"
grep -q "^gh repo create " "$SHIM_LOG" \
  && grep -q "^gh label create " "$SHIM_LOG" \
  && grep -q "^gh api -X PUT " "$SHIM_LOG" \
  && pass "stage writes still execute through gh shim under token-test bypass" \
  || fail "expected stage gh writes missing; log: $SHIM_LOG"

# --- assertion 7: secret skip works with BOOTSTRAP_SKIP_SECRETS=1 ---
: >"$SHIM_LOG"
TARGET2="$WORKDIR/new-repo-skipsec"
rm -rf "$TARGET2"
set +e
unset BOOTSTRAP_REVIEWER_PAT_VALUE
out=$(BOOTSTRAP_SKIP_SECRETS=1 run_wizard skipsec-repo \
        --target-dir "$TARGET2" \
        --description "d" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "BOOTSTRAP_SKIP_SECRETS=1 happy path exits 0" \
  || fail "skip-secrets run failed: rc=$ec"
grep -qF "gh secret set REVIEWER_ASSIGNMENT_TOKEN" "$SHIM_LOG" \
  && fail "secret set called despite BOOTSTRAP_SKIP_SECRETS=1" \
  || pass "BOOTSTRAP_SKIP_SECRETS=1 suppresses gh secret set"

# --- assertion 8: stage fails closed when gh repo create fails ---
: >"$SHIM_LOG"
TARGET3="$WORKDIR/new-repo-fail-create"
rm -rf "$TARGET3"
set +e
out=$(SHIM_EXIT_REPO_CREATE=1 run_wizard failrepo-repo \
        --target-dir "$TARGET3" \
        --description "d" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && pass "stage fails closed when gh repo create fails (rc=$ec)" \
  || fail "stage should fail when gh repo create errors; rc=$ec"
# State file should NOT have github-infra entry (template-mirror is fine
# because that ran before the failure).
if [ -f "$TARGET3/.bootstrap-state" ] && grep -q "^github-infra\$" "$TARGET3/.bootstrap-state"; then
  fail "github-infra recorded despite gh repo create failure"
else
  pass "github-infra NOT recorded when gh repo create fails (resume can retry)"
fi

# --- assertion 9: dry-run produces plan without invoking the shim ---
: >"$SHIM_LOG"
TARGET4="$WORKDIR/new-repo-dry"
rm -rf "$TARGET4"
set +e
dry_out=$(run_wizard dry-repo \
            --target-dir "$TARGET4" \
            --description "d" --visibility private \
            --firebase none --codex-app n --project new --dry-run 2>&1)
dry_ec=$?
set -e
[ "$dry_ec" -eq 0 ] \
  && pass "stage C --dry-run exits 0" \
  || fail "dry-run failed: rc=$dry_ec"
# Dry-run must NOT actually invoke gh (the shim should not have
# recorded anything; bootstrap::run prints [DRY-RUN] instead).
if [ -s "$SHIM_LOG" ]; then
  fail "dry-run invoked gh shim ($(wc -l <"$SHIM_LOG") calls); should be 0"
else
  pass "dry-run did not invoke gh (bootstrap::run honors --dry-run)"
fi
echo "$dry_out" | grep -q "DRY-RUN" \
  && pass "dry-run output includes [DRY-RUN] tags" \
  || fail "dry-run missing [DRY-RUN] markers"

# --- assertion 10: REVIEWER_ASSIGNMENT_TOKEN gh-secret-set failure path
# (nathanpayne-claude review on #239 round 2 — P1).
#
# With set -euo pipefail + a failing `gh secret set` pipeline, the
# pre-fix code aborted the function BEFORE the rc-capture line ran,
# bypassing the err-log + explicit return path. The fix is the
# inline `|| set_rc=$?` pattern matching _provision_llm_secrets.
#
# Drive the failure via SHIM_EXIT_SECRET=1 + a fake PAT. Even with
# the failing secret-set, the stage must complete without any auth
# switch call because token-attributed writes do not mutate global gh
# state.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET5="$WORKDIR/new-repo-secret-fail"
rm -rf "$TARGET5"
set +e
out=$(SHIM_EXIT_SECRET=1 BOOTSTRAP_REVIEWER_PAT_VALUE="fake-pat" run_wizard secretfail-repo \
        --target-dir "$TARGET5" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
# The stage treats secret failures as warned-but-not-fatal (the
# REVIEWER_ASSIGNMENT_TOKEN failure is swallowed via `step_rc=0` in
# the caller), so the wizard SHOULD complete with rc=0. The
# critical invariant is that no global auth switch runs.
[ "$ec" -eq 0 ] \
  && pass "stage completes (rc=0) when secret-set fails (warn-not-fatal)" \
  || fail "stage failed unexpectedly on secret-set failure; rc=$ec, out: $out"
grep -q "^gh auth switch -u" "$SHIM_LOG" \
  && fail "secret failure path invoked gh auth switch; log: $(grep 'auth switch' "$SHIM_LOG")" \
  || pass "secret failure path performs zero gh auth switches"
# The pipeline-rc-capture pattern in scripts/bootstrap/github-infra.sh
# must use `|| set_rc=$?` on the same line as the pipeline so set -e
# doesn't kill the function before the rc handler can run. The match is
# anchored on the `secret set REVIEWER_ASSIGNMENT_TOKEN` argv rather than
# on a `gh secret set` literal: the helper carrying it is the caller's
# choice (bootstrap::author_gh, bootstrap::author_gh_traced), the inline
# rc capture is the invariant.
awk '
  /^bootstrap::_provision_reviewer_assignment_token\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /secret set REVIEWER_ASSIGNMENT_TOKEN.*\|\| set_rc=\$\?/ { saw = 1 }
  END { if (!saw) { print "no `|| set_rc=$?` inline on gh secret set pipeline"; exit 1 } }
' "$ROOT/scripts/bootstrap/github-infra.sh" \
  && pass "_provision_reviewer_assignment_token uses '|| set_rc=\$?' inline on gh secret set pipeline" \
  || fail "rc-capture-inline invariant violated (regression of nathanpayne-claude #239 r2 P1)"

# --- assertion 11: reviewer-PAT op reference defaults (#734) ---
# The default BOOTSTRAP_REVIEWER_PAT_OP_REF must be the item-UUID path;
# title-based op://…/<title>/… paths don't reliably resolve and silently
# shipped repos without REVIEWER_ASSIGNMENT_TOKEN. Guard against the
# stale title path reappearing anywhere in the bootstrap scripts.
# ---------------------------------------------------------------------------
grep -q 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token' "$ROOT/scripts/bootstrap/github-infra.sh" \
  && pass "default reviewer-PAT op ref is the item-UUID path (#734)" \
  || fail "UUID op ref missing from github-infra.sh"
grep -rq 'op://Private/REVIEWER_ASSIGNMENT_PAT' "$ROOT/scripts/bootstrap/" \
  && fail "stale title-based op ref still present in scripts/bootstrap/ (#734 regression)" \
  || pass "no title-based op://…/REVIEWER_ASSIGNMENT_PAT/… reference remains"

# Variant runner without the inline PAT so the cached-env / miss paths
# are reachable (run_wizard pins BOOTSTRAP_REVIEWER_PAT_VALUE). The
# earlier `unset BOOTSTRAP_REVIEWER_PAT_VALUE` (assertion 7) already
# clears it in-process, but pin it to empty here too so this runner
# is self-contained and doesn't depend on ordering against an unset
# ~120 lines earlier — an inherited/exported value from the invoking
# shell would otherwise take precedence and invalidate assertions
# 12-14.
run_wizard_nopat() {
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
  BOOTSTRAP_REVIEWER_PAT_VALUE="" \
  BOOTSTRAP_SKIP_STAGES=board-and-summary \
  "$SCRIPT" "$@"
}

# --- assertion 12: session-cached OP_PREFLIGHT_REVIEWER_PAT is preferred ---
# With no inline PAT, the provisioning step must reuse the cached
# reviewer PAT (no op probe needed) and set the secret (#734) —
# provided the cache's owning agent ($OP_PREFLIGHT_AGENT, exported by
# op-preflight.sh) is among the selected reviewers (#755 round 2).
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET6="$WORKDIR/new-repo-cached-pat"
rm -rf "$TARGET6"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="cached-fake-pat" OP_PREFLIGHT_AGENT="claude" \
        run_wizard_nopat cachedpat-repo \
        --target-dir "$TARGET6" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "cached-PAT run completes (rc=0)" \
  || fail "cached-PAT run failed: rc=$ec, out: $out"
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/cachedpat-repo\$" "$SHIM_LOG" \
  && pass "REVIEWER_ASSIGNMENT_TOKEN set from cached \$OP_PREFLIGHT_REVIEWER_PAT" \
  || fail "secret not set from cached PAT; log: $(grep secret "$SHIM_LOG" || true)"
echo "$out" | grep -q "reusing session-cached" \
  && pass "provisioning logs the cached-PAT path" \
  || fail "missing cached-PAT log line; out: $out"

# --- assertion 12b: cached-PAT identity mismatch falls through ---
# The cached PAT belongs to $OP_PREFLIGHT_AGENT, which may not be in
# the wizard's --reviewers selection. Installing it anyway would make
# the secret authenticate as an uninvited account (#755 round 2,
# Codex P2 x2). With agent=codex but reviewers=claude,cursor (and no
# op on the shim PATH), provisioning must NOT reuse the cache and
# must land on the loud-miss path instead.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET6B="$WORKDIR/new-repo-cached-pat-mismatch"
rm -rf "$TARGET6B"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="cached-fake-pat" OP_PREFLIGHT_AGENT="codex" \
        run_wizard_nopat cachedmismatch-repo \
        --target-dir "$TARGET6B" \
        --reviewers claude,cursor \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "mismatched cached-PAT run still completes (rc=0, default soft-fail)" \
  || fail "mismatched cached-PAT run failed: rc=$ec, out: $out"
grep -qF "gh secret set REVIEWER_ASSIGNMENT_TOKEN" "$SHIM_LOG" \
  && fail "secret set from a cached PAT whose agent is not a selected reviewer" \
  || pass "mismatched cached PAT is NOT installed as the secret"
echo "$out" | grep -q "NOT reusing session-cached" \
  && pass "mismatch fall-through is logged" \
  || fail "missing mismatch log line; out: $out"
echo "$out" | grep -q "ERROR: REVIEWER_ASSIGNMENT_TOKEN: NO PAT available" \
  && pass "mismatch falls through to the loud-miss path" \
  || fail "expected loud miss after mismatch fall-through; out: $out"

# --- assertion 12b-2: the remediation hint must not recommend the
# rejected PAT (#761). gh-as-author.sh verifies the identity of the
# author performing the write, never the token piped on its stdin, so a
# hint that pipes the just-rejected $OP_PREFLIGHT_REVIEWER_PAT would
# install a wrong-identity secret with nothing downstream to catch it.
# The hint must name a SELECTED reviewer's preflight instead.
# ---------------------------------------------------------------------------
echo "$out" | grep -qF "do NOT install the PAT currently in \$OP_PREFLIGHT_REVIEWER_PAT" \
  && pass "remediation warns off the rejected cached PAT" \
  || fail "remediation did not warn off the rejected cached PAT; out: $out"
echo "$out" | grep -qF "it belongs to agent 'codex', which is not one of the selected reviewers (claude,cursor)" \
  && pass "remediation names the rejected PAT's owning agent and the selection" \
  || fail "remediation missing the rejected-agent explanation; out: $out"
echo "$out" | grep -qF 'eval "$(scripts/op-preflight.sh --agent claude --mode review)"' \
  && pass "remediation points at preflight for a SELECTED reviewer (claude)" \
  || fail "remediation missing the selected-reviewer preflight line; out: $out"
echo "$out" | grep -qF "fix: printf '%s' \"\$OP_PREFLIGHT_REVIEWER_PAT\" | scripts/gh-as-author.sh" \
  && fail "remediation still pipes the rejected \$OP_PREFLIGHT_REVIEWER_PAT straight into gh secret set; out: $out" \
  || pass "remediation no longer pipes the rejected PAT directly into gh secret set"
echo "$out" | grep -qF "verifies the account performing the write, NOT the token on its stdin" \
  && pass "remediation states why the wrapper cannot catch a wrong-identity payload" \
  || fail "remediation missing the wrapper-does-not-verify-stdin note; out: $out"

# --- assertion 12c: unverifiable cached-PAT identity also falls through ---
# OP_PREFLIGHT_REVIEWER_PAT set but OP_PREFLIGHT_AGENT unset: identity
# cannot be verified, so the cache must not be installed (fail closed).
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET6C="$WORKDIR/new-repo-cached-pat-noagent"
rm -rf "$TARGET6C"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="cached-fake-pat" OP_PREFLIGHT_AGENT="" \
        run_wizard_nopat cachednoagent-repo \
        --target-dir "$TARGET6C" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
grep -qF "gh secret set REVIEWER_ASSIGNMENT_TOKEN" "$SHIM_LOG" \
  && fail "secret set from a cached PAT with unverifiable agent identity" \
  || pass "cached PAT with unset \$OP_PREFLIGHT_AGENT is NOT installed (fail closed)"
# The remediation must explain the unverifiable-identity case on its own
# terms rather than blaming a reviewer mismatch it cannot prove (#761).
echo "$out" | grep -qF "\$OP_PREFLIGHT_AGENT is unset, so its owning identity could not be verified" \
  && pass "remediation explains the unverifiable cached-PAT identity" \
  || fail "remediation missing the unset-agent explanation; out: $out"

# --- assertion 13: PAT miss is LOUD + recorded, but non-fatal by default ---
# No inline PAT, no cached PAT, no op on the shim PATH, prompts skipped:
# the run must still exit 0 (default soft-fail) but emit ERROR-level
# lines and persist the miss to the .bootstrap-state.warnings sidecar
# the summary re-surfaces (#734).
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET7="$WORKDIR/new-repo-pat-miss"
rm -rf "$TARGET7"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="" run_wizard_nopat patmiss-repo \
        --target-dir "$TARGET7" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "PAT-miss run still exits 0 by default (soft-fail)" \
  || fail "PAT-miss run failed: rc=$ec, out: $out"
grep -qF "gh secret set REVIEWER_ASSIGNMENT_TOKEN" "$SHIM_LOG" \
  && fail "secret set invoked despite no PAT available" \
  || pass "no secret-set call on the miss path"
echo "$out" | grep -q "ERROR: REVIEWER_ASSIGNMENT_TOKEN: NO PAT available" \
  && pass "PAT miss emits ERROR-level lines (loud, #734)" \
  || fail "missing loud ERROR on PAT miss; out: $out"
[ -s "$TARGET7/.bootstrap-state.warnings" ] \
  && grep -q "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned" "$TARGET7/.bootstrap-state.warnings" \
  && pass "PAT miss recorded in .bootstrap-state.warnings sidecar" \
  || fail "warnings sidecar missing or empty: $(cat "$TARGET7/.bootstrap-state.warnings" 2>/dev/null)"
# With no cached PAT there is nothing to warn off, so the rejected-PAT
# line must NOT appear — it is emitted only on positive evidence that a
# cached PAT existed and was refused (#761). The actionable preflight
# remediation still has to be there.
echo "$out" | grep -qF "do NOT install the PAT currently in" \
  && fail "remediation warned off a cached PAT that was never present; out: $out" \
  || pass "no-cached-PAT miss omits the rejected-PAT warning"
echo "$out" | grep -qF 'eval "$(scripts/op-preflight.sh --agent claude --mode review)"' \
  && pass "no-cached-PAT miss still emits the selected-reviewer preflight remediation" \
  || fail "remediation missing on the no-cached-PAT miss; out: $out"

# --- assertion 14: BOOTSTRAP_STRICT_SECRETS=1 upgrades the miss to a
# stage failure (nonzero exit; github-infra not recorded). ---
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET8="$WORKDIR/new-repo-strict-miss"
rm -rf "$TARGET8"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="" BOOTSTRAP_STRICT_SECRETS=1 run_wizard_nopat strictmiss-repo \
        --target-dir "$TARGET8" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && pass "BOOTSTRAP_STRICT_SECRETS=1 fails the run on a PAT miss (rc=$ec)" \
  || fail "strict-secrets run should fail on a PAT miss; rc=$ec, out: $out"
if [ -f "$TARGET8/.bootstrap-state" ] && grep -q "^github-infra\$" "$TARGET8/.bootstrap-state"; then
  fail "github-infra recorded despite strict-secrets PAT miss"
else
  pass "github-infra NOT recorded under strict-secrets PAT miss (resume can retry)"
fi
# End-to-end pin for the reason carry-forward (#761). The provisioning
# helper records the SPECIFIC cause and then returns non-zero under
# strict mode; the stage records under the SAME key, and
# bootstrap::record_warning is replace-by-key. Without the carry-forward
# the stage's own record replaced "no PAT available, prompts skipped"
# with a generic "provisioning failed (rc=1)" and the sidecar could no
# longer distinguish this miss from the human-declined or
# gh-secret-set-failed paths — which is the audit trail the whole #761
# change exists to keep.
grep -qF "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/strictmiss-repo (no PAT available, prompts skipped)" \
     "$TARGET8/.bootstrap-state.warnings" \
  && pass "strict-mode abort keeps the SPECIFIC failure reason in the sidecar (#761)" \
  || fail "strict-mode stage record replaced the specific reason: $(cat "$TARGET8/.bootstrap-state.warnings" 2>/dev/null)"
# The stage-level consequence must still be appended — the operator needs
# to know the run aborted and how to resume, not just why the PAT missed.
grep -qF "BOOTSTRAP_STRICT_SECRETS=1 failed the stage — fix and re-run with --resume template-mirror" \
     "$TARGET8/.bootstrap-state.warnings" \
  && pass "strict-mode abort still appends the stage-level resume remediation" \
  || fail "strict-mode record dropped the resume remediation: $(cat "$TARGET8/.bootstrap-state.warnings" 2>/dev/null)"
# Exactly one line for the key — the carry-forward composes a single
# record, it does not append a second one alongside the specific reason.
[ "$(grep -c '^@reviewer-assignment-token	' "$TARGET8/.bootstrap-state.warnings")" = "1" ] \
  && pass "strict-mode abort leaves exactly one reviewer-assignment-token record" \
  || fail "expected one keyed record, got: $(cat "$TARGET8/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 15: BOOTSTRAP_STRICT_SECRETS=1 + a `gh secret set`
# failure AFTER a PAT was obtained (as opposed to the "no PAT
# available" miss covered by assertion 14) still fails the stage
# AND persists the failure to the warnings sidecar. Before this fix
# the strict branch returned before bootstrap::record_warning ran,
# so the failure vanished from `.bootstrap-state.warnings` the
# moment the stage aborted, leaving no trail for a later --resume
# or a human auditing the sidecar.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET9="$WORKDIR/new-repo-strict-secretset-fail"
rm -rf "$TARGET9"
set +e
out=$(SHIM_EXIT_SECRET=1 BOOTSTRAP_STRICT_SECRETS=1 BOOTSTRAP_REVIEWER_PAT_VALUE="fake-pat" \
        run_wizard strictsecretfail-repo \
        --target-dir "$TARGET9" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && pass "BOOTSTRAP_STRICT_SECRETS=1 fails the run when gh secret set fails after a PAT was obtained (rc=$ec)" \
  || fail "strict-secrets run should fail on a gh-secret-set failure; rc=$ec, out: $out"
if [ -f "$TARGET9/.bootstrap-state" ] && grep -q "^github-infra\$" "$TARGET9/.bootstrap-state"; then
  fail "github-infra recorded despite strict-secrets gh-secret-set failure"
else
  pass "github-infra NOT recorded under strict-secrets gh-secret-set failure (resume can retry)"
fi
[ -s "$TARGET9/.bootstrap-state.warnings" ] \
  && grep -q "REVIEWER_ASSIGNMENT_TOKEN" "$TARGET9/.bootstrap-state.warnings" \
  && pass "strict-secrets gh-secret-set failure recorded in .bootstrap-state.warnings sidecar" \
  || fail "warnings sidecar missing the strict-mode secret-set failure: $(cat "$TARGET9/.bootstrap-state.warnings" 2>/dev/null)"
# The record must name the SPECIFIC cause, not the generic
# "provisioning failed (rc=N)" fallback (#782). Three distinct failures
# share the reviewer-assignment-token key — no PAT with prompts skipped,
# human declined, and `gh secret set` itself failing — and
# docs/agents/bootstrap-runbook.md § Stage C promises the sidecar
# distinguishes them. Before this fix the secret-set path left
# $BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON empty and the stage's
# keyed record fell back to the generic message.
grep -qF "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/strictsecretfail-repo (the gh secret-set call itself failed, rc=1)" \
     "$TARGET9/.bootstrap-state.warnings" \
  && pass "strict-mode secret-set failure names 'gh secret set itself failed' in the sidecar (#782)" \
  || fail "sidecar recorded a generic reason for the secret-set failure: $(cat "$TARGET9/.bootstrap-state.warnings" 2>/dev/null)"
grep -qF "github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=" \
     "$TARGET9/.bootstrap-state.warnings" \
  && fail "secret-set failure still recorded the generic fallback headline: $(cat "$TARGET9/.bootstrap-state.warnings" 2>/dev/null)" \
  || pass "secret-set failure does not fall back to the generic provisioning-failed headline"
# The stage-level consequence is still appended to the specific reason.
grep -qF "BOOTSTRAP_STRICT_SECRETS=1 failed the stage — fix and re-run with --resume template-mirror" \
     "$TARGET9/.bootstrap-state.warnings" \
  && pass "secret-set failure record keeps the stage-level resume remediation" \
  || fail "secret-set failure record dropped the resume remediation: $(cat "$TARGET9/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 15b: successful retry marks the prior token warning RESOLVED ---
# A strict failure records a must-not-miss REVIEWER_ASSIGNMENT_TOKEN
# warning before returning. When the operator fixes credentials and the
# retry successfully sets the secret, that token-specific record must
# stop reading as an outstanding failure — but it must NOT vanish: the
# sidecar is the audit trail, and an operator reading it weeks later
# still wants to know the first attempt failed (#761). The record is
# rewritten in place under the same key with the RESOLVED: marker, and
# the summary reports it in its own block instead of RECORDED FAILURES.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET9B="$WORKDIR/new-repo-strict-secretset-retry"
rm -rf "$TARGET9B"
mkdir -p "$TARGET9B"
set +e
retry_out=$(PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9B"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  BOOTSTRAP_REVIEWER_PAT_VALUE="fixed-fake-pat"
  bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/retry-repo (no PAT available, prompts skipped) — set it manually before the first PR"
  bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/retry-repo" "claude"
  echo "RC=$?"
' 2>&1)
retry_ec=$?
set -e
echo "$retry_out" | grep -q "RC=0" \
  && [ "$retry_ec" -eq 0 ] \
  && pass "successful retry sets REVIEWER_ASSIGNMENT_TOKEN after a recorded failure" \
  || fail "token retry helper failed; rc=$retry_ec; out: $retry_out"
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/retry-repo$" "$SHIM_LOG" \
  && pass "successful retry invoked gh secret set" \
  || fail "successful retry did not invoke gh secret set; log: $(cat "$SHIM_LOG")"
# No line for the key may remain OUTSTANDING — i.e. every surviving
# reviewer-assignment-token line must carry the RESOLVED marker. (The
# original message is deliberately preserved inside that line, so
# grepping for the failure text alone would match the resolved record.)
grep '^@reviewer-assignment-token	' "$TARGET9B/.bootstrap-state.warnings" \
  | grep -qv '	RESOLVED: ' \
  && fail "successful retry left the outstanding REVIEWER_ASSIGNMENT_TOKEN failure: $(cat "$TARGET9B/.bootstrap-state.warnings")" \
  || pass "successful retry retires the outstanding REVIEWER_ASSIGNMENT_TOKEN failure line"
grep -q "^@reviewer-assignment-token" "$TARGET9B/.bootstrap-state.warnings" \
  && pass "resolution record keeps the original warning key (a later re-failure still replaces it)" \
  || fail "resolution record lost the warning key: $(cat "$TARGET9B/.bootstrap-state.warnings" 2>/dev/null)"
grep -q "RESOLVED: " "$TARGET9B/.bootstrap-state.warnings" \
  && pass "successful retry records the miss as RESOLVED instead of erasing it (#761)" \
  || fail "sidecar lost the record that the first attempt failed: $(cat "$TARGET9B/.bootstrap-state.warnings" 2>/dev/null)"
# The ORIGINAL failure message must survive verbatim. Several distinct
# failures share the reviewer-assignment-token key (no PAT + prompts
# skipped / human declined / gh secret set failed); substituting a
# generic "provisioning failed earlier" string would make the audit
# trail unable to answer the question it is kept for.
grep -qF "RESOLVED: REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/retry-repo (no PAT available, prompts skipped)" \
     "$TARGET9B/.bootstrap-state.warnings" \
  && pass "resolution record preserves WHICH failure occurred, not a generic message" \
  || fail "resolution record discarded the original failure message: $(cat "$TARGET9B/.bootstrap-state.warnings" 2>/dev/null)"
grep -qF "[fixed on a later attempt in this bootstrap: the secret is now set on nathanjohnpayne/retry-repo" \
     "$TARGET9B/.bootstrap-state.warnings" \
  && pass "resolution record appends the caller's resolution note" \
  || fail "resolution record dropped the resolution note: $(cat "$TARGET9B/.bootstrap-state.warnings" 2>/dev/null)"
# Resolving twice (operator re-runs --resume a second time) must be
# idempotent: the guard is "outstanding line", not "any line for the
# key", so the marker must not stack and the original must not sink one
# bracket deeper per attempt.
set +e
reresolve_out=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9B"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  bootstrap::_resolve_recorded_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "second pass note"
' 2>&1)
set -e
[ "$(grep -c 'RESOLVED: ' "$TARGET9B/.bootstrap-state.warnings")" = "1" ] \
  && ! grep -qF "second pass note" "$TARGET9B/.bootstrap-state.warnings" \
  && pass "re-resolving an already-RESOLVED record is a no-op (no marker stacking)" \
  || fail "second resolve pass rewrote the resolved record: $(cat "$TARGET9B/.bootstrap-state.warnings"); out: $reresolve_out"
echo "template-mirror" >"$TARGET9B/.bootstrap-state"
echo "github-infra" >>"$TARGET9B/.bootstrap-state"
set +e
summary_out=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9B"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/board-and-summary.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_INPUT_FIREBASE=none
  bootstrap::_print_summary "nathanjohnpayne/retry-repo" "$TARGET" "private" "" "project=skip"
' 2>&1)
summary_ec=$?
set -e
[ "$summary_ec" -eq 0 ] \
  && pass "summary renders after the token warning is resolved" \
  || fail "summary render failed after token warning resolution; rc=$summary_ec; out: $summary_out"
echo "$summary_out" | grep -q "RECORDED FAILURES" \
  && fail "summary printed stale recorded failures after successful token retry: $summary_out" \
  || pass "summary omits the resolved token warning from RECORDED FAILURES"
echo "$summary_out" | grep -qF "ok RESOLVED (recorded earlier in this bootstrap" \
  && pass "summary reports the resolved warning in its own RESOLVED block (#761)" \
  || fail "summary dropped the resolved warning entirely; out: $summary_out"
echo "$summary_out" | grep -qF "ok - REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/retry-repo (no PAT available, prompts skipped)" \
  && pass "RESOLVED block strips the wire-format marker and shows the original failure" \
  || fail "resolved line rendered wrong; out: $summary_out"

# --- assertion 15c: producer and renderer agree on the sidecar marker ---
# The RESOLVED: prefix is the wire format of ${BOOTSTRAP_STATE_FILE}.warnings,
# written by github-infra.sh and read by board-and-summary.sh. Pin the
# two spellings equal so a rename in one file can't silently downgrade
# every resolved record back into a RECORDED FAILURE. The renderer's
# pattern also requires the "@<key><TAB>" prefix the producer always
# writes, so the literal pinned here carries both halves (#781 item 3).
# ---------------------------------------------------------------------------
grep -q 'BOOTSTRAP_WARNING_RESOLVED_MARKER="RESOLVED: "' "$ROOT/scripts/bootstrap/github-infra.sh" \
  && grep -qF "warnings_resolved_re='^@[^	]*	RESOLVED: '" "$ROOT/scripts/bootstrap/board-and-summary.sh" \
  && pass "github-infra.sh and board-and-summary.sh agree on the RESOLVED: sidecar marker" \
  || fail "resolved-warning marker drifted between producer and renderer"

# --- assertion 15d: a first-attempt success records no resolution ---
# bootstrap::_resolve_recorded_warning must be a no-op when nothing was
# recorded for the key — a clean run must not manufacture a resolution
# record for a failure that never happened (and must not create the
# sidecar at all).
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET9C="$WORKDIR/new-repo-first-try-success"
rm -rf "$TARGET9C"
mkdir -p "$TARGET9C"
set +e
clean_out=$(PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9C"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  BOOTSTRAP_REVIEWER_PAT_VALUE="first-try-fake-pat"
  bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/clean-repo" "claude"
' 2>&1)
clean_ec=$?
set -e
[ "$clean_ec" -eq 0 ] \
  && pass "first-attempt token provisioning succeeds (rc=0)" \
  || fail "first-attempt provisioning failed; rc=$clean_ec; out: $clean_out"
[ -e "$TARGET9C/.bootstrap-state.warnings" ] \
  && fail "clean first attempt manufactured a resolution record: $(cat "$TARGET9C/.bootstrap-state.warnings")" \
  || pass "clean first attempt writes no resolution record"

# The no-sidecar case above short-circuits at the file-existence guard,
# so it never reaches the "no OUTSTANDING line for this key" early
# return. Exercise that branch directly: a sidecar that exists but holds
# only OTHER keys must come through a clean first-attempt success
# untouched. Without this fixture, dropping the found-guard would let a
# clean run manufacture a RESOLVED record for a token failure that never
# happened and the suite would still pass.
: >"$SHIM_LOG"
TARGET9C2="$WORKDIR/new-repo-first-try-other-warnings"
rm -rf "$TARGET9C2"
mkdir -p "$TARGET9C2"
printf '@llm-secrets\tANTHROPIC_API_KEY was NOT provisioned — set it manually\n' \
  >"$TARGET9C2/.bootstrap-state.warnings"
printf 'collaborator invite for nathanpayne-codex failed\n' \
  >>"$TARGET9C2/.bootstrap-state.warnings"
set +e
clean2_out=$(PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9C2"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  BOOTSTRAP_REVIEWER_PAT_VALUE="first-try-fake-pat"
  bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/clean2-repo" "claude"
' 2>&1)
clean2_ec=$?
set -e
[ "$clean2_ec" -eq 0 ] \
  && pass "first-attempt success succeeds with unrelated warnings already in the sidecar" \
  || fail "first-attempt provisioning failed with a pre-existing sidecar; rc=$clean2_ec; out: $clean2_out"
grep -q "RESOLVED" "$TARGET9C2/.bootstrap-state.warnings" \
  && fail "clean first attempt manufactured a RESOLVED record over unrelated warnings: $(cat "$TARGET9C2/.bootstrap-state.warnings")" \
  || pass "clean first attempt writes no RESOLVED record when only OTHER keys are recorded"
grep -q "^@reviewer-assignment-token" "$TARGET9C2/.bootstrap-state.warnings" \
  && fail "clean first attempt invented a reviewer-assignment-token record: $(cat "$TARGET9C2/.bootstrap-state.warnings")" \
  || pass "clean first attempt adds no record under the token key"
[ "$(wc -l <"$TARGET9C2/.bootstrap-state.warnings" | tr -d ' ')" = "2" ] \
  && grep -q "ANTHROPIC_API_KEY was NOT provisioned" "$TARGET9C2/.bootstrap-state.warnings" \
  && grep -q "collaborator invite for nathanpayne-codex failed" "$TARGET9C2/.bootstrap-state.warnings" \
  && pass "unrelated recorded warnings survive a clean token provisioning untouched" \
  || fail "unrelated warnings were disturbed: $(cat "$TARGET9C2/.bootstrap-state.warnings")"

# --- assertion 15e: the interactive decline path emits the same
# actionable remediation (#761). A human who declines the paste prompt
# is in exactly the position the hint is written for; leaving that path
# hint-less was the asymmetry the prompts-skipped fix exposed.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET9D="$WORKDIR/new-repo-declined-pat"
rm -rf "$TARGET9D"
mkdir -p "$TARGET9D"
set +e
declined_out=$(PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9D"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  BOOTSTRAP_REVIEWER_PAT_VALUE=""
  OP_PREFLIGHT_REVIEWER_PAT=""
  BOOTSTRAP_AUTO_PROMPT=prompt
  bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/declined-repo" "cursor,codex" <<<""
  echo "RC=$?"
' 2>&1)
declined_ec=$?
set -e
echo "$declined_out" | grep -q "RC=0" \
  && [ "$declined_ec" -eq 0 ] \
  || fail "declined-PAT path did not return 0; rc=$declined_ec; out: $declined_out"
grep -qF "gh secret set REVIEWER_ASSIGNMENT_TOKEN" "$SHIM_LOG" \
  && fail "secret set invoked after the human declined to paste a PAT" \
  || pass "declined-PAT path invokes no gh secret set"
echo "$declined_out" | grep -qF 'eval "$(scripts/op-preflight.sh --agent cursor --mode review)"' \
  && pass "declined-PAT path emits the remediation for the first SELECTED reviewer (cursor)" \
  || fail "declined-PAT path missing the selected-reviewer remediation; out: $declined_out"
grep -q "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned" "$TARGET9D/.bootstrap-state.warnings" \
  && pass "declined-PAT path still records the miss in the warnings sidecar" \
  || fail "declined-PAT path recorded no warning: $(cat "$TARGET9D/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 15f: the remediation is ONE `&&`-chained command ---
# Emitting the re-preflight and the `gh secret set` as two independent
# lines makes the mitigation advisory prose: an operator who copies only
# the line that performs the action, in a shell whose preflight cache
# belongs to a NON-selected agent, installs that rejected PAT — and
# gh-as-author.sh verifies the author performing the write, never the
# token on its stdin, so nothing downstream catches it. Chaining is what
# makes skipping the preflight impossible (#761).
# ---------------------------------------------------------------------------
echo "$declined_out" \
  | grep -qF 'eval "$(scripts/op-preflight.sh --agent cursor --mode review)" && printf '"'"'%s'"'"' "$OP_PREFLIGHT_REVIEWER_PAT" | scripts/gh-as-author.sh -- gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/declined-repo' \
  && pass "remediation chains the re-preflight and the secret write into one command" \
  || fail "remediation emitted the preflight and the gh write as separable lines; out: $declined_out"
echo "$declined_out" | grep -F 'gh secret set REVIEWER_ASSIGNMENT_TOKEN' | grep -qv 'op-preflight.sh' \
  && fail "a gh secret set line is transcribable without the preflight; out: $declined_out" \
  || pass "no gh secret set line appears without its preflight prefix"

# --- assertion 15g: the hinted --agent is one op-preflight accepts ---
# The wizard does NOT validate --reviewers at parse time
# (scripts/bootstrap-new-repo.sh only checks the argument is non-empty),
# while scripts/op-preflight.sh hard-rejects any --agent outside
# claude/cursor/codex. Echoing the first CSV field back verbatim can
# therefore print a remediation that exits 1 — a dead end at exactly the
# moment the operator needs a working command (#761).
# ---------------------------------------------------------------------------
emit_remediation() {
  bash -c '
    ROOT="'"$ROOT"'"
    . "$ROOT/scripts/bootstrap/_lib.sh"
    . "$ROOT/scripts/bootstrap/github-infra.sh"
    BOOTSTRAP_LOG_FILE=""
    OP_PREFLIGHT_REVIEWER_PAT=""
    bootstrap::_emit_reviewer_token_remediation "nathanjohnpayne/hint-repo" "'"$1"'"
  ' 2>&1
}
hint_out=$(emit_remediation "copilot,claude")
echo "$hint_out" | grep -qF -- "--agent claude --mode review" \
  && pass "remediation skips an unsupported reviewer name and picks the first preflight-valid one" \
  || fail "remediation named an agent op-preflight rejects; out: $hint_out"
echo "$hint_out" | grep -qF -- "--agent copilot" \
  && fail "remediation emitted 'copilot', which op-preflight exits 1 on; out: $hint_out" \
  || pass "remediation never emits an --agent op-preflight would reject"
# --- assertion 15g-2: the unsupported-reviewer remediation is runnable ---
# When NO selected reviewer is an agent op-preflight knows, there is no
# cached PAT to re-preflight for. The hint used to emit the chained
# command anyway with a literal `<selected-reviewer>` in the --agent
# slot — a line the operator cannot run: `<` and `>` are shell
# redirection metacharacters, so pasting it yields a redirect/syntax
# error rather than the remediation (#781 item 4). The replacement is a
# command with no placeholder in it at all.
# ---------------------------------------------------------------------------
for selection in "copilot" ""; do
  label=${selection:-<empty>}
  hint_out=$(emit_remediation "$selection")
  echo "$hint_out" | grep -qF -- "<selected-reviewer>" \
    && fail "unsupported-reviewer remediation ($label) still emits the <selected-reviewer> placeholder; out: $hint_out" \
    || pass "unsupported-reviewer remediation ($label) emits no <selected-reviewer> placeholder"
  # Stronger than a single-placeholder grep: the emitted command lines
  # (the ones indented under "REVIEWER_ASSIGNMENT_TOKEN:   ") must carry
  # no angle bracket at all. `<` / `>` are shell redirection operators,
  # so ANY `<foo>` placeholder makes the line do something other than
  # what it reads as when pasted — that is precisely what made the old
  # hint unrunnable.
  cmdlines=$(echo "$hint_out" | sed -n 's/^\[bootstrap\] ERROR: REVIEWER_ASSIGNMENT_TOKEN:   //p')
  [ -n "$cmdlines" ] \
    && pass "unsupported-reviewer remediation ($label) emits a command line" \
    || fail "unsupported-reviewer remediation ($label) emitted no command line; out: $hint_out"
  printf '%s\n' "$cmdlines" | grep -q '[<>]' \
    && fail "unsupported-reviewer remediation ($label) command carries a shell-redirect placeholder: $cmdlines" \
    || pass "unsupported-reviewer remediation ($label) command is free of angle-bracket placeholders"
  echo "$hint_out" | grep -qF "none of the selected reviewers ($selection) is an agent scripts/op-preflight.sh can resolve a PAT for (it accepts: claude cursor codex)" \
    && pass "unsupported-reviewer remediation ($label) names the unusable selection and the accepted set" \
    || fail "unsupported-reviewer remediation ($label) did not explain why preflight cannot help; out: $hint_out"
  echo "$hint_out" | grep -qF "scripts/gh-as-author.sh -- gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/hint-repo" \
    && pass "unsupported-reviewer remediation ($label) emits the direct token-verified secret-set command" \
    || fail "unsupported-reviewer remediation ($label) emitted no runnable secret-set command; out: $hint_out"
  # The chained preflight form must NOT appear: with no valid agent it
  # could only name a placeholder or a non-selected agent's cache.
  echo "$hint_out" | grep -qF "op-preflight.sh --agent" \
    && fail "unsupported-reviewer remediation ($label) still emits an op-preflight invocation; out: $hint_out" \
    || pass "unsupported-reviewer remediation ($label) drops the unusable op-preflight route"
  # ...and it must not tell the operator to pipe the session cache in,
  # which is what the && chain exists to prevent on the valid-agent path.
  echo "$hint_out" | grep -qF 'printf '"'"'%s'"'"' "$OP_PREFLIGHT_REVIEWER_PAT" | scripts/gh-as-author.sh' \
    && fail "unsupported-reviewer remediation ($label) pipes \$OP_PREFLIGHT_REVIEWER_PAT with no preflight; out: $hint_out" \
    || pass "unsupported-reviewer remediation ($label) never pipes the session cache"
done

# The known-agent list is a local mirror of op-preflight's. Pin the two
# equal so an agent added there cannot silently go missing here (the
# same drift guard assertion 15c applies to the RESOLVED: marker).
preflight_agents=$(sed -n '/^reviewer_pat_item_for()/,/^}/p' "$ROOT/scripts/op-preflight.sh" \
  | sed -n 's/^[[:space:]]*\([a-z][a-z]*\))[[:space:]]*echo.*/\1/p' | tr '\n' ' ' | sed 's/ *$//')
infra_agents=$(sed -n 's/^BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS="\(.*\)"$/\1/p' \
  "$ROOT/scripts/bootstrap/github-infra.sh")
[ -n "$preflight_agents" ] \
  && [ "$preflight_agents" = "$infra_agents" ] \
  && pass "BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS matches op-preflight's accepted agent set" \
  || fail "agent set drifted: op-preflight='$preflight_agents' github-infra='$infra_agents'"

# --- assertion 15h: the carried reason describes THIS attempt only ---
# Two attempts in ONE process, exactly as --resume re-enters the stage.
# Attempt 1 fails with "no PAT available, prompts skipped"; attempt 2
# fails differently (a PAT was obtained, then `gh secret set` failed).
# The sidecar has no timestamp or run marker, so a stale line from
# attempt 1 is byte-indistinguishable from a fresh one — which is why the
# fix is a carried out-parameter reset on entry, NOT a "never overwrite an
# existing record for this key" guard. The guard would pin attempt 1's
# reason in place and silently drop attempt 2's genuine failure. Both
# directions are pinned here:
#   forward  — attempt 1's specific reason survives the stage-level record;
#   backward — attempt 2 records its OWN cause and replaces the stale
#              record (record_warning's replace-by-key contract).
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET9H="$WORKDIR/new-repo-reason-carry"
rm -rf "$TARGET9H"
mkdir -p "$TARGET9H"
CARRY_TAIL="BOOTSTRAP_STRICT_SECRETS=1 failed the stage — fix and re-run with --resume template-mirror"
set +e
carry_out=$(PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" SHIM_EXIT_SECRET=1 bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9H"'"
  TAIL="'"$CARRY_TAIL"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1
  BOOTSTRAP_AUTO_PROMPT=skip
  BOOTSTRAP_STRICT_SECRETS=1
  OP_PREFLIGHT_REVIEWER_PAT=""

  # Attempt 1: no PAT anywhere, prompts skipped -> specific reason.
  BOOTSTRAP_REVIEWER_PAT_VALUE=""
  rc1=0
  bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/carry-repo" "claude" || rc1=$?
  bootstrap::_record_reviewer_token_stage_failure "$rc1" "$TAIL"
  cp "$BOOTSTRAP_STATE_FILE.warnings" "$TARGET/after-attempt1.warnings"

  # Attempt 2, same process: a PAT is available now, but the secret-set
  # itself fails. That path records nothing of its own.
  BOOTSTRAP_REVIEWER_PAT_VALUE="fixed-fake-pat"
  rc2=0
  bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/carry-repo" "claude" || rc2=$?
  bootstrap::_record_reviewer_token_stage_failure "$rc2" "$TAIL"
  echo "RC1=$rc1 RC2=$rc2"
' 2>&1)
carry_ec=$?
set -e
echo "$carry_out" | grep -q "RC1=1 RC2=1" \
  && [ "$carry_ec" -eq 0 ] \
  && pass "both carry-forward attempts failed as designed (strict mode, rc=1 each)" \
  || fail "carry-forward harness did not fail as expected; rc=$carry_ec; out: $carry_out"
# Forward direction.
grep -qF "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/carry-repo (no PAT available, prompts skipped)" \
     "$TARGET9H/after-attempt1.warnings" \
  && pass "attempt 1's specific reason survives the stage-level keyed record" \
  || fail "stage record clobbered attempt 1's reason: $(cat "$TARGET9H/after-attempt1.warnings" 2>/dev/null)"
# Backward direction: the stale specific reason must NOT survive a NEW
# failure whose path recorded no reason of its own.
grep -qF "no PAT available, prompts skipped" "$TARGET9H/.bootstrap-state.warnings" \
  && fail "attempt 2 inherited attempt 1's stale reason: $(cat "$TARGET9H/.bootstrap-state.warnings" 2>/dev/null)" \
  || pass "a later failure that records no reason of its own does not inherit the stale one"
grep -qF "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on nathanjohnpayne/carry-repo (the gh secret-set call itself failed, rc=1) — set it manually before the first PR; $CARRY_TAIL" \
     "$TARGET9H/.bootstrap-state.warnings" \
  && pass "attempt 2 replaces the stale record with its OWN specific cause" \
  || fail "attempt 2 did not record its own cause: $(cat "$TARGET9H/.bootstrap-state.warnings" 2>/dev/null)"
[ "$(grep -c '^@reviewer-assignment-token	' "$TARGET9H/.bootstrap-state.warnings")" = "1" ] \
  && pass "replacement leaves exactly one reviewer-assignment-token record" \
  || fail "expected one keyed record after replacement: $(cat "$TARGET9H/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 15h-2: the generic fallback is still wired ---
# Every failing provisioning path now publishes a specific reason (#782),
# so the recorder's generic branch is unreachable through
# bootstrap::_provision_reviewer_assignment_token. It stays as defence in
# depth for a future path that forgets to publish one, and that branch
# must keep working — exercise it directly with an empty out-parameter.
# ---------------------------------------------------------------------------
TARGET9H2="$WORKDIR/new-repo-generic-fallback"
rm -rf "$TARGET9H2"
mkdir -p "$TARGET9H2"
set +e
fallback_out=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$TARGET9H2"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/github-infra.sh"
  BOOTSTRAP_STATE_FILE="$TARGET/.bootstrap-state"
  BOOTSTRAP_LOG_FILE=""
  BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON=""
  bootstrap::_record_reviewer_token_stage_failure 7 "tail note"
' 2>&1)
fallback_ec=$?
set -e
[ "$fallback_ec" -eq 0 ] \
  && grep -qF "github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=7); tail note" \
       "$TARGET9H2/.bootstrap-state.warnings" \
  && pass "recorder still falls back to the generic headline when no reason is published" \
  || fail "generic fallback broke; rc=$fallback_ec; out: $fallback_out; sidecar: $(cat "$TARGET9H2/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 15i: a wrapper failure is NOT recorded as a gh failure ---
# scripts/gh-as-author.sh can fail BEFORE it ever starts gh — byline pin
# refusal (exit 2), author token lookup failure (exit 3) — and the rc
# alone cannot be told from `gh secret set` running and failing. Recording
# "the gh secret-set call itself failed" for a token-lookup failure sends
# the operator to replace the reviewer PAT when the thing to repair is
# AUTHOR authentication. bootstrap::author_gh_traced settles it with
# positive proof: a marker the wrapped command writes immediately before
# it exec's gh.
#
# Both directions run through a REAL wrapper (BOOTSTRAP_SKIP_AUTHOR_TOKEN
# is deliberately unset, so the traced call takes its wrapper branch):
#   (a) a wrapper that exits 3 without running the wrapped command;
#   (b) a wrapper that forwards the wrapped command, whose gh then fails.
# ---------------------------------------------------------------------------
run_secret_set_failure_case() {
  # $1 = fake-root dir holding scripts/gh-as-author.sh, $2 = target dir,
  # $3 = optional $BOOTSTRAP_LOG_FILE path (default: none configured)
  PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" SHIM_EXIT_SECRET=1 bash -c '
    ROOT="'"$ROOT"'"
    . "$ROOT/scripts/bootstrap/_lib.sh"
    . "$ROOT/scripts/bootstrap/github-infra.sh"
    BOOTSTRAP_MERGEPATH_ROOT="'"$1"'"
    BOOTSTRAP_STATE_FILE="'"$2"'/.bootstrap-state"
    BOOTSTRAP_LOG_FILE="'"${3:-}"'"
    BOOTSTRAP_DRY_RUN=0
    BOOTSTRAP_SKIP_AUTHOR_TOKEN=0
    BOOTSTRAP_AUTO_PROMPT=skip
    BOOTSTRAP_STRICT_SECRETS=1
    BOOTSTRAP_REVIEWER_PAT_VALUE="fake-pat"
    OP_PREFLIGHT_REVIEWER_PAT=""
    rc=0
    bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/wrapperfail-repo" "claude" || rc=$?
    bootstrap::_record_reviewer_token_stage_failure "$rc" "tail note"
    echo "RC=$rc"
  ' 2>&1
}

# (a) wrapper refuses before running anything.
: >"$SHIM_LOG"
FAKE_ROOT_REFUSE="$WORKDIR/fake-root-wrapper-refuse"
TARGET9I="$WORKDIR/new-repo-wrapper-refuse"
rm -rf "$FAKE_ROOT_REFUSE" "$TARGET9I"
mkdir -p "$FAKE_ROOT_REFUSE/scripts" "$TARGET9I"
cat >"$FAKE_ROOT_REFUSE/scripts/gh-as-author.sh" <<'REFUSE_EOF'
#!/bin/sh
# Stand-in for scripts/gh-as-author.sh's pre-`gh` failure modes: it
# never runs the wrapped command (exit 3 = author token lookup failed).
echo "gh-as-author: could not read a token for nathanjohnpayne via gh auth token --user." >&2
exit 3
REFUSE_EOF
chmod +x "$FAKE_ROOT_REFUSE/scripts/gh-as-author.sh"
set +e
refuse_out=$(run_secret_set_failure_case "$FAKE_ROOT_REFUSE" "$TARGET9I")
refuse_ec=$?
set -e
echo "$refuse_out" | grep -q "RC=3" && [ "$refuse_ec" -eq 0 ] \
  && pass "wrapper pre-gh failure propagates its rc (3) out of provisioning" \
  || fail "wrapper-refusal harness misbehaved; rc=$refuse_ec; out: $refuse_out"
grep -q "secret set" "$SHIM_LOG" \
  && fail "gh was invoked even though the wrapper refused; log: $(cat "$SHIM_LOG")" \
  || pass "the refusing wrapper never reached gh (no secret-set in the shim log)"
grep -qF "the gh secret-set call itself failed" "$TARGET9I/.bootstrap-state.warnings" \
  && fail "wrapper failure recorded as a gh secret-set failure: $(cat "$TARGET9I/.bootstrap-state.warnings")" \
  || pass "wrapper failure is NOT recorded as 'the gh secret-set call itself failed'"
grep -qF "the author write path failed before the gh secret-set call ran, rc=3" \
     "$TARGET9I/.bootstrap-state.warnings" \
  && pass "wrapper failure records an author-authentication cause instead" \
  || fail "sidecar does not name the author write path: $(cat "$TARGET9I/.bootstrap-state.warnings" 2>/dev/null)"
echo "$refuse_out" | grep -q "this is an AUTHOR-authentication failure" \
  && pass "the operator-facing ERROR lines point at author auth, not the reviewer PAT" \
  || fail "no author-auth ERROR line emitted; out: $refuse_out"

# (b) wrapper forwards the wrapped command; gh itself fails. This also
# proves the marker survives the real wrapper's exec path.
: >"$SHIM_LOG"
FAKE_ROOT_FORWARD="$WORKDIR/fake-root-wrapper-forward"
TARGET9I2="$WORKDIR/new-repo-wrapper-forward"
rm -rf "$FAKE_ROOT_FORWARD" "$TARGET9I2"
mkdir -p "$FAKE_ROOT_FORWARD/scripts" "$TARGET9I2"
cat >"$FAKE_ROOT_FORWARD/scripts/gh-as-author.sh" <<'FWD_EOF'
#!/bin/sh
# Stand-in for a wrapper whose token resolution SUCCEEDS: it runs
# whatever follows `--`, exactly as scripts/gh-as-author.sh does.
[ "$1" = "--" ] && shift
exec "$@"
FWD_EOF
chmod +x "$FAKE_ROOT_FORWARD/scripts/gh-as-author.sh"
set +e
fwd_out=$(run_secret_set_failure_case "$FAKE_ROOT_FORWARD" "$TARGET9I2")
fwd_ec=$?
set -e
echo "$fwd_out" | grep -q "RC=1" && [ "$fwd_ec" -eq 0 ] \
  && pass "a forwarded secret-set propagates gh's own rc (1)" \
  || fail "wrapper-forward harness misbehaved; rc=$fwd_ec; out: $fwd_out"
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/wrapperfail-repo\$" "$SHIM_LOG" \
  && pass "the forwarding wrapper reaches gh with argv unchanged by the trace shim" \
  || fail "gh argv changed or gh was not reached; log: $(cat "$SHIM_LOG")"
grep -qF "the gh secret-set call itself failed, rc=1" "$TARGET9I2/.bootstrap-state.warnings" \
  && pass "a real gh failure is still recorded as a gh secret-set failure" \
  || fail "gh failure lost its specific cause: $(cat "$TARGET9I2/.bootstrap-state.warnings" 2>/dev/null)"

# --- assertion 15j: the pre-gh diagnostic is where the record says ---
# The record for the pre-gh branch names the author write path, but the
# remediation detail — WHICH token lookup failed, which identity the
# byline pin wanted — is the wrapper's own message, and the wizard
# installs no global stderr tee while bootstrap::run logs command lines
# without their output. Telling an operator the wrapper's error is in
# .bootstrap-log while it exists only in the terminal ends the search at
# a file that never had it. Pinned in three directions: with a log file
# the text is really appended AND still shown live; without one the
# record must not claim a log; and the gh-reached branch must not
# persist a capture taken after the pipeline read the piped PAT.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET9J="$WORKDIR/new-repo-wrapper-refuse-logged"
rm -rf "$TARGET9J"
mkdir -p "$TARGET9J"
LOG9J="$TARGET9J/.bootstrap-log"
set +e
logged_out=$(run_secret_set_failure_case "$FAKE_ROOT_REFUSE" "$TARGET9J" "$LOG9J")
logged_ec=$?
set -e
echo "$logged_out" | grep -q "RC=3" && [ "$logged_ec" -eq 0 ] \
  && pass "logged wrapper-refusal harness reproduces the pre-gh failure (rc=3)" \
  || fail "logged harness misbehaved; rc=$logged_ec; out: $logged_out"
# The wrapper's own words, indented under a header by
# bootstrap::append_log_diagnostic — the indent proves the text arrived
# through the persist path and is not some other line that happens to
# mention the same failure.
grep -qF "captured output follows" "$LOG9J" \
  && pass "the run log carries a captured-output header for the pre-gh failure" \
  || fail "no captured-output header in the run log: $(cat "$LOG9J" 2>/dev/null)"
grep -qE '^    gh-as-author: could not read a token for nathanjohnpayne' "$LOG9J" \
  && pass "the wrapper's own diagnostic is persisted to the run log" \
  || fail "wrapper diagnostic missing from the run log: $(cat "$LOG9J" 2>/dev/null)"
# Persisting must not come at the cost of the live view.
echo "$logged_out" | grep -qF "gh-as-author: could not read a token for nathanjohnpayne" \
  && pass "the wrapper's diagnostic is still shown on the terminal" \
  || fail "capturing the diagnostic swallowed it; out: $logged_out"
grep -qF "the wrapper's own error is in the run log" "$TARGET9J/.bootstrap-state.warnings" \
  && pass "the record points at the run log, which now really holds the diagnostic" \
  || fail "record does not point at the log: $(cat "$TARGET9J/.bootstrap-state.warnings" 2>/dev/null)"
# Fallback: case (a) above ran with BOOTSTRAP_LOG_FILE unset, so there
# was no log to append to and the record must not send anyone to one.
grep -qF "the wrapper's own error is in the run log" "$TARGET9I/.bootstrap-state.warnings" \
  && fail "record points at a run log that was never written: $(cat "$TARGET9I/.bootstrap-state.warnings")" \
  || pass "with no log file the record makes no run-log claim"
grep -qF "the wrapper's own error is in the terminal output above" \
     "$TARGET9I/.bootstrap-state.warnings" \
  && pass "with no log file the record points at the terminal instead" \
  || fail "no terminal fallback in the record: $(cat "$TARGET9I/.bootstrap-state.warnings" 2>/dev/null)"
# The gh-reached branch keeps its capture terminal-only: by then the
# pipeline has read the piped PAT, and that record claims nothing about
# a log, so there is no false pointer to repair by persisting it.
: >"$SHIM_LOG"
TARGET9J2="$WORKDIR/new-repo-wrapper-forward-logged"
rm -rf "$TARGET9J2"
mkdir -p "$TARGET9J2"
LOG9J2="$TARGET9J2/.bootstrap-log"
set +e
fwdlog_out=$(run_secret_set_failure_case "$FAKE_ROOT_FORWARD" "$TARGET9J2" "$LOG9J2")
fwdlog_ec=$?
set -e
echo "$fwdlog_out" | grep -q "RC=1" && [ "$fwdlog_ec" -eq 0 ] \
  && pass "logged wrapper-forward harness reproduces the gh failure (rc=1)" \
  || fail "logged forward harness misbehaved; rc=$fwdlog_ec; out: $fwdlog_out"
# There IS a capture to decline here — the shim gh prints a diagnostic
# before it exits — so the assertion below cannot pass on an empty file.
echo "$fwdlog_out" | grep -qF "gh: HTTP 403: Resource not accessible by personal access token" \
  && pass "the gh-reached branch captured a non-empty diagnostic and showed it" \
  || fail "no gh diagnostic captured, so the no-persist check would be vacuous; out: $fwdlog_out"
grep -qF "captured output follows" "$LOG9J2" 2>/dev/null \
  && fail "post-PAT-read output was persisted on the gh-reached branch: $(cat "$LOG9J2")" \
  || pass "the gh-reached branch persists no capture"
grep -qF "HTTP 403" "$LOG9J2" 2>/dev/null \
  && fail "gh's own post-PAT-read output reached the run log: $(cat "$LOG9J2")" \
  || pass "gh's post-PAT-read output stays out of the run log"
grep -qF "in the run log" "$TARGET9J2/.bootstrap-state.warnings" \
  && fail "the gh-reached record claims a log entry it never wrote: $(cat "$TARGET9J2/.bootstrap-state.warnings")" \
  || pass "the gh-reached record makes no run-log claim"

# --- assertion 16: dry-run PAT miss is pure (#755 round 2) ---
# A dry run carries no credentials, so a PAT miss there is EXPECTED:
# it must print [DRY-RUN] plan lines, write NO .bootstrap-state.warnings
# sidecar, emit no ERROR-level loud-miss lines about a repo that was
# never created, and NOT fail under BOOTSTRAP_STRICT_SECRETS=1.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET10="$WORKDIR/new-repo-dry-pat-miss"
rm -rf "$TARGET10"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="" BOOTSTRAP_STRICT_SECRETS=1 \
        run_wizard_nopat drypatmiss-repo \
        --target-dir "$TARGET10" \
        --description d --visibility private \
        --firebase none --codex-app n --project new --dry-run 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "dry-run PAT miss exits 0 even under BOOTSTRAP_STRICT_SECRETS=1" \
  || fail "dry-run PAT miss failed under strict-secrets: rc=$ec, out: $out"
echo "$out" | grep -q "\[DRY-RUN\] REVIEWER_ASSIGNMENT_TOKEN" \
  && pass "dry-run PAT miss prints [DRY-RUN] plan lines" \
  || fail "missing [DRY-RUN] REVIEWER_ASSIGNMENT_TOKEN plan lines; out: $out"
echo "$out" | grep -q "ERROR: REVIEWER_ASSIGNMENT_TOKEN: NO PAT available" \
  && fail "dry-run PAT miss emitted the live-run loud-miss ERROR lines" \
  || pass "dry-run PAT miss emits no loud-miss ERROR lines"
[ -f "$TARGET10/.bootstrap-state.warnings" ] \
  && fail "dry-run PAT miss wrote the warnings sidecar: $(cat "$TARGET10/.bootstrap-state.warnings")" \
  || pass "dry-run PAT miss writes no .bootstrap-state.warnings sidecar"
[ -s "$SHIM_LOG" ] \
  && fail "dry-run PAT miss invoked gh; log: $(cat "$SHIM_LOG")" \
  || pass "dry-run PAT miss invokes no gh commands"

# --- assertion 16b: dry-run never probes 1Password (#755 round 3) ---
# With op ON the PATH and claude among the selected reviewers, the
# path-a2 probe used to run BEFORE the dry-run early return — a dry
# run could trigger biometric auth and retrieve the real reviewer PAT.
# Shim op, re-run the dry-run miss, and assert zero op invocations.
# ---------------------------------------------------------------------------
OP_SHIM_LOG="$WORKDIR/op-shim.log"
: >"$OP_SHIM_LOG"
cat >"$SHIM_DIR/op" <<OP_EOF
#!/bin/sh
echo "op \$*" >>"$OP_SHIM_LOG"
echo "fake-pat-from-op"
OP_EOF
chmod +x "$SHIM_DIR/op"
TARGET10B="$WORKDIR/new-repo-dry-op-probe"
rm -rf "$TARGET10B"
set +e
out=$(OP_PREFLIGHT_REVIEWER_PAT="" BOOTSTRAP_STRICT_SECRETS=1 \
        run_wizard_nopat dryopprobe-repo \
        --target-dir "$TARGET10B" \
        --description d --visibility private \
        --firebase none --codex-app n --project new --dry-run 2>&1)
ec=$?
set -e
rm -f "$SHIM_DIR/op"
[ "$ec" -eq 0 ] \
  && pass "dry-run with op on PATH still exits 0" \
  || fail "dry-run with op shim failed: rc=$ec, out: $out"
[ -s "$OP_SHIM_LOG" ] \
  && fail "dry-run probed 1Password (op invoked): $(cat "$OP_SHIM_LOG")" \
  || pass "dry-run never invokes op (no biometric / PAT retrieval in dry-run)"

# --- assertion 17: resume preflight accepts the warnings sidecar ---
# The preflight's bookkeeping allowlist must treat .bootstrap-state.warnings
# (written by bootstrap::record_warning) like the other resume
# bookkeeping files; before this fix any run that recorded a warning
# poisoned its own --resume with "target dir is not empty" (#755
# round 2). Record a warning through the real helper, then assert a
# resume run gets past preflight.
# ---------------------------------------------------------------------------
TARGET11="$WORKDIR/new-repo-resume-warn"
rm -rf "$TARGET11"
mkdir -p "$TARGET11"
(
  export BOOTSTRAP_STATE_FILE="$TARGET11/.bootstrap-state"
  # shellcheck disable=SC1091
  . "$FAKE_MP/scripts/bootstrap/_lib.sh"
  bootstrap::record_warning "seeded warning for the resume-allowlist regression test"
) >/dev/null 2>&1
[ -s "$TARGET11/.bootstrap-state.warnings" ] \
  || fail "test setup: record_warning did not write the warnings sidecar"
echo "template-mirror" >"$TARGET11/.bootstrap-state"
: >"$TARGET11/.bootstrap-log"
set +e
out=$(run_wizard_nopat resumewarn-repo \
        --target-dir "$TARGET11" \
        --description d --visibility private \
        --firebase none --codex-app n --project new --dry-run --resume 2>&1)
ec=$?
set -e
echo "$out" | grep -q "is not empty" \
  && fail "resume preflight rejected a dir containing only bookkeeping + warnings sidecar; out: $out" \
  || pass "resume preflight accepts the .bootstrap-state.warnings sidecar"
[ "$ec" -eq 0 ] \
  && pass "resume run with a warnings sidecar completes (rc=$ec)" \
  || fail "resume run with a warnings sidecar failed: rc=$ec, out: $out"
echo "$out" | grep -q "resume: skip template-mirror" \
  && pass "resume actually skipped the recorded template-mirror stage" \
  || fail "resume did not skip template-mirror; out: $out"

# --- assertion 18: a strict-secrets abort after repo creation is
# resumable (#761 item 3).
#
# Stage C creates the remote FIRST and records stage completion LAST, so
# a BOOTSTRAP_STRICT_SECRETS=1 abort in the secret step leaves a created
# remote that nothing records. The stage's own remediation says to re-run
# with `--resume template-mirror`, and that was impossible: the wizard's
# preflight rejected the populated target dir AND the now-existing
# remote, and had it got past both, stage C would have called
# `gh repo create` on a name that already exists.
#
# The fix is a post-create checkpoint. This drives the real two-run
# sequence end to end: run 1 aborts under strict mode after the remote is
# created; run 2 resumes in the SAME target dir with credentials fixed.
# Run 2 deliberately does NOT set BOOTSTRAP_SKIP_TOOL_CHECK, because the
# existing-remote probe is one of the two gates being tested and it is
# suppressed by that flag. That needs `op` on the shim PATH for
# preflight's dependency check.
# ---------------------------------------------------------------------------
cat >"$SHIM_DIR/op" <<'OP_EOF'
#!/bin/sh
# op shim for the resume preflight: present on PATH for the dependency
# check, but resolves no PAT (the resume run supplies one inline).
exit 1
OP_EOF
chmod +x "$SHIM_DIR/op"

run_wizard_toolcheck() {
  PATH="$SHIM_PATH" \
  SHIM_LOG="$SHIM_LOG" \
  BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
  BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 \
  BOOTSTRAP_AUTO_PROMPT=skip \
  BOOTSTRAP_AUTHOR_NAME="test" \
  BOOTSTRAP_AUTHOR_EMAIL="t@t" \
  BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 \
  BOOTSTRAP_SKIP_INVITE_PAUSE=1 \
  BOOTSTRAP_REVIEWER_PAT_VALUE="fake-test-pat-1234567890" \
  BOOTSTRAP_SKIP_STAGES=board-and-summary \
  "$SCRIPT" "$@"
}

# Run 1: strict abort in the secret step, AFTER the remote was created.
: >"$SHIM_LOG"
TARGET12="$WORKDIR/new-repo-strict-resume"
rm -rf "$TARGET12"
set +e
out=$(SHIM_EXIT_SECRET=1 BOOTSTRAP_STRICT_SECRETS=1 run_wizard strictresume-repo \
        --target-dir "$TARGET12" \
        --description d --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && pass "strict-secrets run 1 aborts after the remote was created (rc=$ec)" \
  || fail "strict-secrets run 1 should have failed; rc=$ec, out: $out"
grep -q "^gh repo create nathanjohnpayne/strictresume-repo " "$SHIM_LOG" \
  && pass "strict-secrets run 1 did create the remote before aborting" \
  || fail "run 1 never reached gh repo create; log: $(cat "$SHIM_LOG")"
[ -f "$TARGET12/.bootstrap-state.checkpoints" ] \
  && grep -qxF "github-infra:remote-created:nathanjohnpayne/strictresume-repo" "$TARGET12/.bootstrap-state.checkpoints" \
  && pass "the created remote is recorded in .bootstrap-state.checkpoints, bound to its owner/name" \
  || fail "no remote-created checkpoint after run 1: $(cat "$TARGET12/.bootstrap-state.checkpoints" 2>/dev/null)"
grep -qxF "github-infra:remote-created" "$TARGET12/.bootstrap-state.checkpoints" \
  && fail "a repo-less checkpoint was recorded; it would match any remote: $(cat "$TARGET12/.bootstrap-state.checkpoints")" \
  || pass "no bare step-only checkpoint is recorded"
grep -q "^github-infra\$" "$TARGET12/.bootstrap-state" \
  && fail "github-infra recorded despite the strict abort" \
  || pass "github-infra still NOT recorded (the stage did not finish)"

# Run 2: the operator fixes credentials and resumes, exactly as the
# stage's own recorded remediation instructs.
: >"$SHIM_LOG"
set +e
resume_out=$(run_wizard_toolcheck strictresume-repo \
               --target-dir "$TARGET12" \
               --description d --visibility private \
               --firebase none --codex-app n --project new \
               --resume template-mirror 2>&1)
resume_ec=$?
set -e
echo "$resume_out" | grep -q "is not empty" \
  && fail "resume preflight rejected the target dir the earlier stages populated; out: $resume_out" \
  || pass "resume preflight accepts a target dir populated by earlier stages"
echo "$resume_out" | grep -q "remote already exists" \
  && fail "resume preflight rejected the remote this bootstrap created; out: $resume_out" \
  || pass "resume preflight accepts the remote recorded by the checkpoint"
[ "$resume_ec" -eq 0 ] \
  && pass "strict-secrets abort is resumable with --resume template-mirror (rc=0)" \
  || fail "resume run failed; rc=$resume_ec; out: $resume_out"
grep -q "^gh repo create " "$SHIM_LOG" \
  && fail "resume re-invoked gh repo create on an existing remote; log: $(cat "$SHIM_LOG")" \
  || pass "resume skips gh repo create (checkpointed step is idempotent)"
echo "$resume_out" | grep -q "skipping gh repo create" \
  && pass "resume logs why the create was skipped" \
  || fail "resume did not log the checkpoint skip; out: $resume_out"
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/strictresume-repo\$" "$SHIM_LOG" \
  && pass "resume completes the step that failed (REVIEWER_ASSIGNMENT_TOKEN set)" \
  || fail "resume never retried the secret; log: $(cat "$SHIM_LOG")"
grep -q "^github-infra\$" "$TARGET12/.bootstrap-state" \
  && pass "resume records github-infra completion" \
  || fail "state file still missing github-infra: $(cat "$TARGET12/.bootstrap-state" 2>/dev/null)"

# --- assertion 18b: the checkpoint is bound to the repo it created ---
# The sidecar lives in the target dir, but the repository comes from the
# positional argument + $BOOTSTRAP_REPO_OWNER, and --target-dir lets a
# second run reuse the same tree under a DIFFERENT name. A step-only
# checkpoint ("this bootstrap created a remote") would therefore relax
# both guards for any owner/name: a mistyped resume would pass preflight
# against an unrelated existing repo, skip the create, and go on to seed
# labels, invite reviewers and write REVIEWER_ASSIGNMENT_TOKEN into it.
# TARGET12 still holds run 1's checkpoint for strictresume-repo; both
# layers are pinned against a resume that names hijack-repo instead.
# ---------------------------------------------------------------------------
# Layer 1 — preflight refuses the unrelated existing remote.
: >"$SHIM_LOG"
set +e
hijack_out=$(run_wizard_toolcheck hijack-repo \
               --target-dir "$TARGET12" \
               --description d --visibility private \
               --firebase none --codex-app n --project new \
               --resume template-mirror 2>&1)
hijack_ec=$?
set -e
[ "$hijack_ec" -eq 2 ] \
  && pass "a resume naming a different repo in the same target dir fails preflight (rc=2)" \
  || fail "resume onto an unrelated repo should exit 2; rc=$hijack_ec; out: $hijack_out"
echo "$hijack_out" | grep -q "remote already exists: nathanjohnpayne/hijack-repo" \
  && pass "preflight refuses the unrelated remote despite a checkpoint for another repo" \
  || fail "existing-remote guard did not fire for the unnamed repo; out: $hijack_out"
grep -q -- "--repo nathanjohnpayne/hijack-repo" "$SHIM_LOG" \
  && fail "the refused resume still wrote to the unrelated repo; log: $(cat "$SHIM_LOG")" \
  || pass "the refused resume performed no writes against the unrelated repo"

# Layer 2 — with preflight's remote probe suppressed (BOOTSTRAP_SKIP_TOOL_CHECK=1,
# as run_wizard sets), the stage itself must still not adopt the earlier
# run's create: it creates hijack-repo's OWN remote.
: >"$SHIM_LOG"
set +e
hijack2_out=$(run_wizard hijack-repo \
                --target-dir "$TARGET12" \
                --description d --visibility private \
                --firebase none --codex-app n --project new \
                --resume template-mirror 2>&1)
hijack2_ec=$?
set -e
[ "$hijack2_ec" -eq 0 ] \
  && pass "stage-level hijack probe ran to completion (rc=0)" \
  || fail "stage-level hijack probe failed; rc=$hijack2_ec; out: $hijack2_out"
grep -q "^gh repo create nathanjohnpayne/hijack-repo " "$SHIM_LOG" \
  && pass "step 1 creates the named repo's own remote instead of inheriting the checkpointed skip" \
  || fail "gh repo create for hijack-repo was skipped by another repo's checkpoint; log: $(cat "$SHIM_LOG")"
grep -qxF "github-infra:remote-created:nathanjohnpayne/hijack-repo" "$TARGET12/.bootstrap-state.checkpoints" \
  && pass "the second create records its own repo-bound checkpoint" \
  || fail "hijack-repo create recorded no bound checkpoint: $(cat "$TARGET12/.bootstrap-state.checkpoints" 2>/dev/null)"

# --- assertion 18c: the existing-remote relaxation is checkpoint-gated ---
# Positive proof only. Without the checkpoint an existing remote still
# fails preflight closed, so `--resume` can never be used to bootstrap
# over a repo this run did not create.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
rm -f "$TARGET12/.bootstrap-state.checkpoints"
set +e
nocp_out=$(run_wizard_toolcheck strictresume-repo \
             --target-dir "$TARGET12" \
             --description d --visibility private \
             --firebase none --codex-app n --project new \
             --resume template-mirror 2>&1)
nocp_ec=$?
set -e
[ "$nocp_ec" -eq 2 ] \
  && pass "resume without the checkpoint fails preflight (rc=2)" \
  || fail "resume without the checkpoint should exit 2; rc=$nocp_ec; out: $nocp_out"
echo "$nocp_out" | grep -q "remote already exists" \
  && pass "resume without the checkpoint still refuses the existing remote" \
  || fail "existing-remote guard did not fire without the checkpoint; out: $nocp_out"
[ -s "$SHIM_LOG" ] \
  && ! grep -q "^gh repo create " "$SHIM_LOG" \
  && pass "the refused resume never reached gh repo create" \
  || fail "refused resume behaved unexpectedly; log: $(cat "$SHIM_LOG")"

# --- assertion 18d: a dry run never writes a checkpoint ---
# bootstrap::record_checkpoint records what the wizard DID, not what it
# said it would do. A dry-run checkpoint would make a LATER live run skip
# a `gh repo create` that never happened, against a remote that does not
# exist.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET13="$WORKDIR/new-repo-dry-checkpoint"
rm -rf "$TARGET13"
set +e
out=$(run_wizard drycheckpoint-repo \
        --target-dir "$TARGET13" \
        --description d --visibility private \
        --firebase none --codex-app n --project new --dry-run 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "dry run with the checkpoint machinery exits 0" \
  || fail "dry run failed; rc=$ec, out: $out"
[ -e "$TARGET13/.bootstrap-state.checkpoints" ] \
  && fail "dry run wrote a remote-created checkpoint: $(cat "$TARGET13/.bootstrap-state.checkpoints")" \
  || pass "dry run writes no .bootstrap-state.checkpoints sidecar"

# --- assertion 18e: a created remote whose PUSH failed is still
# checkpointed, and the resume retries only the push (#790).
#
# As one `gh repo create --source --push` the two halves shared a single
# exit code: a push that failed on a transient network / credential error
# returned non-zero with the repository already created, and the
# checkpoint — written only after the whole command succeeded — was never
# recorded. The remote existed, nothing recorded it, and the documented
# `--resume template-mirror` retry was then refused by preflight's
# existing-remote check. The most likely-to-be-transient failure in the
# stage produced the one state the checkpoint exists to prevent.
#
# Split into two commands, the create's success is checkpointed
# immediately and the push is an ordinary repeatable step. Driven end to
# end: run 1 creates the remote and fails the push; the operator fixes
# the cause; run 2 resumes and pushes.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
TARGET14="$WORKDIR/new-repo-push-fail"
rm -rf "$TARGET14"
set +e
pf_out=$(SHIM_PUSH_BROKEN=1 run_wizard pushfail-repo \
           --target-dir "$TARGET14" \
           --description d --visibility private \
           --firebase none --codex-app n --project new 2>&1)
pf_ec=$?
set -e
[ "$pf_ec" -ne 0 ] \
  && pass "a failed push fails the stage (rc=$pf_ec)" \
  || fail "push-failure run should have failed; rc=$pf_ec, out: $pf_out"
grep -q "^gh repo create nathanjohnpayne/pushfail-repo " "$SHIM_LOG" \
  && pass "push-failure run did create the remote" \
  || fail "run never reached gh repo create; log: $(cat "$SHIM_LOG")"
echo "$pf_out" | grep -q "push bootstrap commit to nathanjohnpayne/pushfail-repo" \
  && pass "push-failure run attempted the push as its own step" \
  || fail "no push step attempted; out: $pf_out"
[ -f "$TARGET14/.bootstrap-state.checkpoints" ] \
  && grep -qxF "github-infra:remote-created:nathanjohnpayne/pushfail-repo" "$TARGET14/.bootstrap-state.checkpoints" \
  && pass "the created remote is checkpointed even though the push failed" \
  || fail "no remote-created checkpoint after a failed push: $(cat "$TARGET14/.bootstrap-state.checkpoints" 2>/dev/null)"
grep -q "^github-infra\$" "$TARGET14/.bootstrap-state" \
  && fail "github-infra recorded despite the failed push" \
  || pass "github-infra still NOT recorded (the stage did not finish)"

# The operator fixes the transient cause: the remote is reachable again.
git init -q --bare "$WORKDIR/remotes/pushfail-repo.git"
: >"$SHIM_LOG"
set +e
pf2_out=$(run_wizard_toolcheck pushfail-repo \
            --target-dir "$TARGET14" \
            --description d --visibility private \
            --firebase none --codex-app n --project new \
            --resume template-mirror 2>&1)
pf2_ec=$?
set -e
echo "$pf2_out" | grep -q "remote already exists" \
  && fail "preflight refused the remote created before the push failed; out: $pf2_out" \
  || pass "preflight accepts the remote whose push failed (checkpoint present)"
[ "$pf2_ec" -eq 0 ] \
  && pass "a failed push is resumable with --resume template-mirror (rc=0)" \
  || fail "push-failure resume failed; rc=$pf2_ec; out: $pf2_out"
grep -q "^gh repo create " "$SHIM_LOG" \
  && fail "resume re-invoked gh repo create on the existing remote; log: $(cat "$SHIM_LOG")" \
  || pass "resume skips the create"
echo "$pf2_out" | grep -q "push bootstrap commit to nathanjohnpayne/pushfail-repo" \
  && pass "resume retries the push it skipped the create for" \
  || fail "resume did not retry the push; out: $pf2_out"
git -C "$WORKDIR/remotes/pushfail-repo.git" rev-parse --verify -q refs/heads/main >/dev/null \
  && pass "the bootstrap commit reached the remote on the retry" \
  || fail "remote still has no main after the resume"
grep -q "^github-infra\$" "$TARGET14/.bootstrap-state" \
  && pass "resume records github-infra completion" \
  || fail "state file still missing github-infra: $(cat "$TARGET14/.bootstrap-state" 2>/dev/null)"
rm -f "$SHIM_DIR/op"

# --- assertion 18f: the split push still runs under the VERIFIED author
# credential (#790 round 4).
#
# As one `gh repo create --source --push`, a single bootstrap::run_author_gh
# call covered both halves: gh created the remote AND pushed under the
# author token scripts/gh-as-author.sh had resolved and verified.
# Splitting the commands must not split them off that credential. A bare
# `git push` takes its credential from the machine's ambient
# credential-helper state instead — it fails or prompts on a clean or
# non-author setup, and where some OTHER configured account has access it
# silently populates the new repo's main under the wrong identity, which
# is the mis-attribution class this repo's author/reviewer separation
# exists to make impossible.
#
# Driven through a REAL wrapper (BOOTSTRAP_SKIP_AUTHOR_TOKEN=0), so
# nothing reaches gh or git without passing through
# scripts/gh-as-author.sh first, and the stand-in wrapper records every
# command it was handed.
# ---------------------------------------------------------------------------
# $1 = fake-root dir holding scripts/gh-as-author.sh, $2 = target dir,
# $3 = owner/name to create, $4 = file the wrapper appends its argv to.
run_create_and_push_case() {
  PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" WRAPPER_LOG="$4" bash -c '
    ROOT="'"$ROOT"'"
    . "$ROOT/scripts/bootstrap/_lib.sh"
    . "$ROOT/scripts/bootstrap/github-infra.sh"
    BOOTSTRAP_MERGEPATH_ROOT="'"$1"'"
    BOOTSTRAP_STATE_FILE="'"$2"'/.bootstrap-state"
    BOOTSTRAP_DRY_RUN=0
    BOOTSTRAP_SKIP_AUTHOR_TOKEN=0
    rc=0
    bootstrap::_create_remote_and_push \
      "'"$3"'" private "a test repo" "'"$2"'" || rc=$?
    echo "RC=$rc"
  ' 2>&1
}

# A target tree in the state stage B leaves behind: a git repo on main
# with one commit and no origin (the gh shim adds origin on create).
mk_push_target() {
  rm -rf "$1"
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo seed >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
    commit -q -m "Initial commit (bootstrapped from mergepath)"
}

FAKE_ROOT_AUTHPUSH="$WORKDIR/fake-root-author-push"
rm -rf "$FAKE_ROOT_AUTHPUSH"
mkdir -p "$FAKE_ROOT_AUTHPUSH/scripts"
cat >"$FAKE_ROOT_AUTHPUSH/scripts/gh-as-author.sh" <<'AUTHPUSH_EOF'
#!/bin/sh
# Stand-in for scripts/gh-as-author.sh. Records the command it was asked
# to run — which is what proves a call went through the verified author
# path at all — and then runs it the way the real wrapper does: the
# resolved author token in GH_TOKEN, GITHUB_TOKEN cleared.
printf '%s\n' "$*" >>"${WRAPPER_LOG:?WRAPPER_LOG not set}"
[ "$1" = "--" ] && shift
unset GITHUB_TOKEN
GH_TOKEN="fake-author-token-for-the-push" exec "$@"
AUTHPUSH_EOF
chmod +x "$FAKE_ROOT_AUTHPUSH/scripts/gh-as-author.sh"

: >"$SHIM_LOG"
T18F="$WORKDIR/new-repo-author-push"
WRAPPER_LOG18F="$WORKDIR/wrapper-author-push.log"
mk_push_target "$T18F"
: >"$WRAPPER_LOG18F"
set +e
ap_out=$(run_create_and_push_case "$FAKE_ROOT_AUTHPUSH" "$T18F" \
           "nathanjohnpayne/authpush-repo" "$WRAPPER_LOG18F")
ap_ec=$?
set -e
echo "$ap_out" | grep -q "RC=0" && [ "$ap_ec" -eq 0 ] \
  && pass "author-credential harness completes step 1 end to end (rc=0)" \
  || fail "author-credential harness misbehaved; rc=$ap_ec; out: $ap_out"
# Sanity: the create half was always wrapped, so a wrapper log that
# recorded nothing would mean the harness never ran, not that the push
# is unwrapped.
grep -qF "gh repo create nathanjohnpayne/authpush-repo" "$WRAPPER_LOG18F" \
  && pass "the create runs through the author wrapper (harness is live)" \
  || fail "the wrapper recorded no create; log: $(cat "$WRAPPER_LOG18F")"
# The finding itself.
# `|| true`: with `set -o pipefail` a no-match grep would abort the whole
# suite on the assignment, and a regression here has to be REPORTED, not
# turned into a silent early exit that skips every assertion after it.
push_line=$(grep -F "push -u origin HEAD" "$WRAPPER_LOG18F" | tail -1 || true)
[ -n "$push_line" ] \
  && pass "the bootstrap push runs through the author wrapper too" \
  || fail "the push never reached the author wrapper (ambient git credentials); log: $(cat "$WRAPPER_LOG18F")"
# ...and carries the credential wiring, so the wrapper's token is what
# git authenticates with rather than whatever helper the machine had
# configured. The reset and the gh helper must be adjacent and in that
# order: an appended helper without the reset leaves the inherited ones
# ahead of it in the list.
printf '%s\n' "$push_line" \
  | grep -qF -- "-c credential.helper= -c credential.helper=!gh auth git-credential" \
  && pass "the push clears inherited credential helpers and takes gh's" \
  || fail "push carries no gh credential wiring: $push_line"
printf '%s\n' "$push_line" | grep -qF "GIT_TERMINAL_PROMPT=0" \
  && pass "the push disables git's terminal prompt" \
  || fail "push can still prompt on the terminal: $push_line"
printf '%s\n' "$push_line" | grep -qF "GIT_ASKPASS=" \
  && pass "the push closes the askpass prompt path" \
  || fail "push can still raise an askpass dialog: $push_line"
# The credential travels over the helper protocol, so it must not appear
# in the remote URL or anywhere else git wrote to disk (reflog included).
git -C "$T18F" remote get-url origin | grep -qF "fake-author-token" \
  && fail "the token leaked into the remote URL: $(git -C "$T18F" remote get-url origin)" \
  || pass "the remote URL carries no token"
grep -rqF "fake-author-token-for-the-push" "$T18F/.git" 2>/dev/null \
  && fail "the token leaked into the local git dir (config / reflog)" \
  || pass "the token stays out of the local git dir"
grep -rqF "fake-author-token-for-the-push" "$WORKDIR/remotes/authpush-repo.git" 2>/dev/null \
  && fail "the token leaked into the remote repository" \
  || pass "the token stays out of the remote repository"
# And it really pushed — the wiring must not have broken the transfer.
git -C "$WORKDIR/remotes/authpush-repo.git" rev-parse --verify -q refs/heads/main >/dev/null \
  && pass "the wrapped push still lands the bootstrap commit on the remote" \
  || fail "remote has no main after the wrapped push"

# --- assertion 18g: the credential wiring the push carries really does
# resolve the wrapper's token — checked against the REAL git and gh.
#
# Asserting the flags are PRESENT only proves the shape. The flags are
# taken straight from $BOOTSTRAP_GIT_CREDENTIAL_ARGS / the non-interactive
# env, so this probe cannot drift from what ships, and it runs the real
# tools: `gh auth git-credential get` answers from $GH_TOKEN with no
# network call, so a fake token is enough to show which credential git
# would hand the remote. Nothing here contacts GitHub.
#
# The probe output is never echoed. With the wiring broken the fallback
# is the developer's own credential helper, and that answer can be a
# REAL token.
# ---------------------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  PROBE_TOKEN="probe-token-not-a-real-credential-4f2a"
  set +e
  probe_out=$(
    . "$ROOT/scripts/bootstrap/_lib.sh"
    printf 'protocol=https\nhost=github.com\n\n' \
      | env -u GITHUB_TOKEN GH_TOKEN="$PROBE_TOKEN" \
            "${BOOTSTRAP_GIT_NONINTERACTIVE_ENV[@]}" \
            git "${BOOTSTRAP_GIT_CREDENTIAL_ARGS[@]}" credential fill 2>&1
  )
  set -e
  probe_pw=$(printf '%s\n' "$probe_out" | sed -n 's/^password=//p')
  probe_rest=$(printf '%s\n' "$probe_out" | grep -v '^password=' || true)
  [ "$probe_pw" = "$PROBE_TOKEN" ] \
    && pass "the shipped credential wiring resolves git's password from the wrapper's GH_TOKEN" \
    || fail "credential wiring did not yield the wrapper's token (password line redacted); other output: $probe_rest"
  printf '%s\n' "$probe_rest" | grep -qF "username=x-access-token" \
    && pass "gh answers the credential request as the token-bearing user" \
    || fail "unexpected credential username; output: $probe_rest"
else
  echo "SKIP: gh not installed — cannot probe the real credential helper" >&2
fi

# --- assertion 18h: a checkpoint that does not get written fails the
# stage before the push (#790 round 4).
#
# bootstrap::record_checkpoint is called immediately after the one
# irreversible act in the stage, and its rc was ignored. Stage functions
# run under `|| stage_rc=$?`, so errexit is disabled through this whole
# call chain: an append that failed (unwritable sidecar, full disk) did
# not stop anything. The run carried on to the push, the labels, the
# invites and the secret — and an abort in any of them left the remote
# created with nothing recording it, which is the state the checkpoint
# was added to prevent: the create cannot be repeated and preflight
# refuses the documented `--resume template-mirror`.
#
# The sidecar is made unwritable by putting a DIRECTORY where the append
# expects a file. That fails for every user including root, unlike a
# chmod a root test runner would sail straight through.
# ---------------------------------------------------------------------------
: >"$SHIM_LOG"
T18H="$WORKDIR/new-repo-checkpoint-unwritable"
WRAPPER_LOG18H="$WORKDIR/wrapper-checkpoint-fail.log"
mk_push_target "$T18H"
: >"$WRAPPER_LOG18H"
mkdir -p "$T18H/.bootstrap-state.checkpoints"
set +e
cf_out=$(run_create_and_push_case "$FAKE_ROOT_AUTHPUSH" "$T18H" \
           "nathanjohnpayne/checkpointfail-repo" "$WRAPPER_LOG18H")
cf_ec=$?
set -e
echo "$cf_out" | grep -q "RC=0" \
  && fail "an unrecorded create was treated as success; out: $cf_out" \
  || pass "a checkpoint write that does not land fails the stage"
[ "$cf_ec" -eq 0 ] \
  && pass "checkpoint-failure harness ran to completion" \
  || fail "checkpoint-failure harness misbehaved; rc=$cf_ec; out: $cf_out"
# It must be the POST-create path being tested: the create really ran.
grep -q "^gh repo create nathanjohnpayne/checkpointfail-repo " "$SHIM_LOG" \
  && pass "the irreversible create happened before the checkpoint write" \
  || fail "the run never reached gh repo create; log: $(cat "$SHIM_LOG")"
# ...and the stage stopped there rather than pushing on.
grep -qF "push -u origin HEAD" "$WRAPPER_LOG18H" \
  && fail "the stage pushed past an unrecorded create; log: $(cat "$WRAPPER_LOG18H")" \
  || pass "the stage does not push past an unrecorded create"
git -C "$WORKDIR/remotes/checkpointfail-repo.git" rev-parse --verify -q refs/heads/main >/dev/null 2>&1 \
  && fail "the bootstrap commit was pushed despite the failed checkpoint" \
  || pass "nothing reached the remote after the failed checkpoint"
# The operator has to be able to repair it by hand — the remote exists
# and the create cannot be repeated.
echo "$cf_out" | grep -qF "resume checkpoint could not be written" \
  && pass "the failure names the checkpoint write as the cause" \
  || fail "no checkpoint-write diagnostic; out: $cf_out"
echo "$cf_out" | grep -qF "github-infra:remote-created:nathanjohnpayne/checkpointfail-repo" \
  && pass "the failure prints the exact line to add by hand" \
  || fail "no manual-repair line emitted; out: $cf_out"
echo "$cf_out" | grep -qF -- "--resume template-mirror" \
  && pass "the failure points at the documented resume path" \
  || fail "no resume remediation; out: $cf_out"

# --- assertion 19: a failed temp-dir allocation refuses the secret
# write instead of misreporting it (#790).
#
# `set -e` is disabled inside _provision_reviewer_assignment_token (the
# stage calls it as `... || step_rc=$?`), so an unchecked `mktemp -d`
# failure fell through with an empty dir: the trace marker became
# `/gh-reached` and the capture `/output`. Unprivileged, the redirect
# alone failed with no marker written, and the "which layer failed"
# branch reported an AUTHOR-AUTHENTICATION failure for what is really a
# broken TMPDIR — sending the operator to re-mint tokens. Privileged, it
# would have run the write and left root-owned files at `/`.
# ---------------------------------------------------------------------------
run_secret_set_with_tmpdir() {
  # $1 = fake-root dir holding scripts/gh-as-author.sh, $2 = target dir,
  # $3 = TMPDIR value to run under.
  PATH="$SHIM_PATH" SHIM_LOG="$SHIM_LOG" TMPDIR="$3" bash -c '
    ROOT="'"$ROOT"'"
    . "$ROOT/scripts/bootstrap/_lib.sh"
    . "$ROOT/scripts/bootstrap/github-infra.sh"
    BOOTSTRAP_MERGEPATH_ROOT="'"$1"'"
    BOOTSTRAP_STATE_FILE="'"$2"'/.bootstrap-state"
    BOOTSTRAP_DRY_RUN=0
    BOOTSTRAP_SKIP_AUTHOR_TOKEN=0
    BOOTSTRAP_AUTO_PROMPT=skip
    BOOTSTRAP_REVIEWER_PAT_VALUE="fake-pat"
    OP_PREFLIGHT_REVIEWER_PAT=""
    rc=0
    bootstrap::_provision_reviewer_assignment_token "nathanjohnpayne/tmpfail-repo" "claude" || rc=$?
    bootstrap::_record_reviewer_token_stage_failure "$rc" "tail note"
    echo "RC=$rc"
  ' 2>&1
}

: >"$SHIM_LOG"
FAKE_ROOT_TMPFAIL="$WORKDIR/fake-root-tmpfail"
TARGET15="$WORKDIR/new-repo-tmpfail"
rm -rf "$FAKE_ROOT_TMPFAIL" "$TARGET15"
mkdir -p "$FAKE_ROOT_TMPFAIL/scripts" "$TARGET15"
# A wrapper that WOULD forward to gh, so nothing but the temp-dir guard
# can stop the write.
cat >"$FAKE_ROOT_TMPFAIL/scripts/gh-as-author.sh" <<'TMPFWD_EOF'
#!/bin/sh
[ "$1" = "--" ] && shift
exec "$@"
TMPFWD_EOF
chmod +x "$FAKE_ROOT_TMPFAIL/scripts/gh-as-author.sh"
set +e
tmpfail_out=$(run_secret_set_with_tmpdir "$FAKE_ROOT_TMPFAIL" "$TARGET15" \
                "$WORKDIR/no-such-tmpdir")
set -e
echo "$tmpfail_out" | grep -q "RC=1" \
  && pass "an unallocatable temp dir fails provisioning (rc=1)" \
  || fail "expected rc=1 from the temp-dir guard; out: $tmpfail_out"
grep -q "secret set" "$SHIM_LOG" \
  && fail "the secret write ran without its trace/capture files; log: $(cat "$SHIM_LOG")" \
  || pass "no secret-set call is attempted when the temp dir cannot be allocated"
echo "$tmpfail_out" | grep -q "could not allocate a temporary directory" \
  && pass "the ERROR lines name the temp dir as the cause" \
  || fail "no temp-dir diagnostic; out: $tmpfail_out"
grep -qF "could not allocate a temporary directory" "$TARGET15/.bootstrap-state.warnings" \
  && pass "the recorded cause names the temp dir" \
  || fail "sidecar does not name the temp dir: $(cat "$TARGET15/.bootstrap-state.warnings" 2>/dev/null)"
grep -qF "the author write path failed before the gh secret-set call ran" \
     "$TARGET15/.bootstrap-state.warnings" \
  && fail "a temp-dir failure was recorded as an author-authentication failure: $(cat "$TARGET15/.bootstrap-state.warnings")" \
  || pass "a temp-dir failure is NOT misreported as an author-auth failure"
[ -e /gh-reached ] || [ -e /output ] \
  && fail "the guard let the empty-path fallbacks reach the filesystem root" \
  || pass "no root-level /gh-reached or /output artifacts"

# --- assertion 20: an unallocatable temp dir must not ERASE the
# warnings sidecar (#790).
#
# bootstrap::clear_warning rewrites the sidecar through a tmpfile. With
# an unchecked mktemp the tmpfile path was empty, every append failed,
# and `[ -s "" ]` landed on the "nothing survived the filter" branch —
# which deletes the sidecar. A full /tmp would have erased the whole
# run's audit trail, which is the #734 silent-ship failure the sidecar
# exists to prevent.
# ---------------------------------------------------------------------------
TARGET16="$WORKDIR/new-repo-clearwarn-tmpfail"
rm -rf "$TARGET16"
mkdir -p "$TARGET16"
(
  export BOOTSTRAP_STATE_FILE="$TARGET16/.bootstrap-state"
  # shellcheck disable=SC1091
  . "$FAKE_MP/scripts/bootstrap/_lib.sh"
  bootstrap::record_warning "some-key" "an earlier failure worth keeping"
  bootstrap::record_warning "an unkeyed failure worth keeping"
  # Reproduce the REAL call shape. Stage helpers are invoked as
  # `helper || step_rc=$?`, which disables errexit for the whole dynamic
  # extent of the call — including the bootstrap::record_warning ->
  # bootstrap::clear_warning chain inside them. That is what lets a
  # failed mktemp fall through to the delete branch instead of aborting;
  # calling clear_warning bare here would abort on the assignment and
  # prove nothing.
  attempt_clear() { TMPDIR="$WORKDIR/no-such-tmpdir" bootstrap::clear_warning "some-key"; }
  # The assignment itself reproduces the stage call shape.
  clear_rc=0
  # shellcheck disable=SC2034
  attempt_clear || clear_rc=$?
) >/dev/null 2>&1 || true
[ -f "$TARGET16/.bootstrap-state.warnings" ] \
  && pass "the warnings sidecar survives an unallocatable temp dir" \
  || fail "clear_warning deleted the sidecar when mktemp failed"
grep -qF "an unkeyed failure worth keeping" "$TARGET16/.bootstrap-state.warnings" \
  && pass "unrelated records survive the failed rewrite" \
  || fail "records lost: $(cat "$TARGET16/.bootstrap-state.warnings" 2>/dev/null)"

# --- summary --------------------------------------------------------------
echo
echo "test_bootstrap_github_infra: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
