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
#      description, source, --push).
#   2. All 12 canonical labels are seeded with --force (idempotency).
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
      create) exit "${SHIM_EXIT_REPO_CREATE:-0}" ;;
      *) exit 0 ;;
    esac
    ;;
  label)
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
grep -q "^gh repo create nathanjohnpayne/test-repo --private --description a test repo --source=$TARGET --push$" "$SHIM_LOG" \
  && pass "gh repo create invoked with --private + --source + --push" \
  || fail "gh repo create flags wrong; log: $(grep '^gh repo create' "$SHIM_LOG")"

# --- assertion 2: all 12 labels seeded with --force ---
expected_labels=(needs-external-review needs-human-review policy-violation human-hold human-action decision-needed agent-action phase-0 phase-1 phase-2 phase-3 phase-4)
seeded=0
for label in "${expected_labels[@]}"; do
  if grep -qE "^gh label create $label .* --force\$" "$SHIM_LOG"; then
    seeded=$((seeded + 1))
  else
    fail "label '$label' not seeded with --force; log: $(grep "label create $label" "$SHIM_LOG")"
  fi
done
[ "$seeded" -eq 12 ] \
  && pass "all 12 canonical labels seeded with --force" \
  || fail "expected 12 labels, got $seeded"

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
# doesn't kill the function before the rc handler can run.
awk '
  /^bootstrap::_provision_reviewer_assignment_token\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /gh secret set REVIEWER_ASSIGNMENT_TOKEN.*\|\| set_rc=\$\?/ { saw = 1 }
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
  && grep -q "REVIEWER_ASSIGNMENT_TOKEN provisioning failed" "$TARGET9/.bootstrap-state.warnings" \
  && pass "strict-secrets gh-secret-set failure recorded in .bootstrap-state.warnings sidecar" \
  || fail "warnings sidecar missing the strict-mode secret-set failure: $(cat "$TARGET9/.bootstrap-state.warnings" 2>/dev/null)"

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

# --- summary --------------------------------------------------------------
echo
echo "test_bootstrap_github_infra: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
