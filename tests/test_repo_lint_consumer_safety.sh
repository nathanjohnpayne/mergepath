#!/usr/bin/env bash
# tests/test_repo_lint_consumer_safety.sh — hub-only consumer-safety net
# for the #601 repo_lint.yml wiring-propagation contract.
#
# repo_lint.yml is manifest-canonical (consumers: all) as of #601, so
# EVERY `run: ./scripts/ci/check_*` step in it executes on every consumer
# on every push/PR after the first sync wave. This suite builds a
# consumer-shaped fixture tree — the current checkout minus everything a
# consumer does not have — and runs every check wired in repo_lint.yml
# against it, asserting each exits 0 (PASS or SKIP). A check that fails
# here would red every consumer's repo-lint on the first #601 wave.
#
# Consumer shape modeled (worst case, matching the live-consumer audit
# recorded in check_propagation_closure's ALLOW_LIST, 2026-06-24):
#   - the bootstrap template-mirror excludes are absent
#     (BOOTSTRAP_MIRROR_EXCLUDES in scripts/bootstrap/template-mirror.sh):
#     .mergepath-sync.yml, scripts/sync-to-downstream.sh, the
#     project-doc-sync surface, mergepath/, packaging/, dist/, ...
#   - the hub-only files named in check_propagation_closure's ALLOW_LIST
#     are absent: bootstrap seeders + their tests, the weekly sweep
#     pipeline, the 1Password headless-proof tooling, and the self-tests
#     of hub-only checks. Live consumers were bootstrapped from older
#     template snapshots and verifiably carry none of these.
#   Everything manifest-propagated (canonical entries, kits, requires:)
#   stays present — that is exactly what a post-#601 sync guarantees.
#
# Scope note: every wired check runs; there is currently no exclusion
# list. If a future check is irreducibly hub-entangled, prefer giving it
# the standard consumer SKIP guard (scripts/sync-to-downstream.sh marker
# — see check_sync_manifest) over excluding it here.
#
# Hub-only: this test is deliberately NOT in .mergepath-sync.yml (like
# tests/test_bootstrap*, it encodes hub-only surfaces — including the
# removal list above) and is not itself consumer-safe.
#
# Deterministic + offline: `gh` is PATH-shimmed to fail closed (wired
# checks must be hermetic — a check that reaches for live gh on a
# consumer runner would be flaky there too); the fixture is git-init'ed
# so git-based checks (git ls-files / rev-parse) see a plain consumer
# repo. yq + node + ruby + rsync are required (the repo-lint workflow
# provides all of them on every runner); missing tooling → SKIP.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in yq node ruby rsync git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not available" >&2
    exit 0
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-consumer-safety.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build the consumer-shaped fixture tree.
# ---------------------------------------------------------------------------
FIX="$WORKDIR/consumer"
mkdir -p "$FIX"

# NB: exclude '.git' WITHOUT a trailing slash. In a linked git WORKTREE
# checkout, .git is a FILE (a gitdir pointer into the main repo), not a
# directory — '.git/' would not match it, the pointer would be copied
# into the fixture, and every fixture git command would then operate on
# the REAL repo (this bit once: a fixture `git commit` landed on the
# real branch).
rsync -a \
  --exclude='.git' \
  --exclude='node_modules/' \
  --exclude='.DS_Store' \
  "$ROOT/" "$FIX/"
rm -rf "$FIX/.git"

# Consumer-absent paths. Two sources of truth, kept in the header
# comment above:
#   (a) BOOTSTRAP_MIRROR_EXCLUDES (scripts/bootstrap/template-mirror.sh)
#   (b) check_propagation_closure's ALLOW_LIST (hub-only, never travels)
# Globs are intentional (expanded by the loop below).
CONSUMER_ABSENT=(
  # (a) template-mirror excludes — never even seeded at bootstrap.
  ".mergepath-sync.yml"
  "scripts/sync-to-downstream.sh"
  "tests/test_sync_to_downstream.sh"
  ".github/workflows/weekly-drift-audit.yml"
  ".mergepath-project-docs.yml"
  "docs/projects"
  "scripts/project-doc-sync.sh"
  "tests/test_project_doc_sync.sh"
  "mergepath"
  "packaging"
  "dist"
  "scripts/policy-sim.sh"
  "specs/mergepath_playground.md"
  "plans/mergepath-playground.md"
  "tests/test_mergepath_playground.sh"
  "bugs/screenshots"
  ".github/screenshots"
  # (b) hub-only per check_propagation_closure ALLOW_LIST — absent from
  # live consumers (older bootstrap snapshots; never manifest-propagated).
  "scripts/bootstrap.sh"
  "scripts/bootstrap-new-repo.sh"
  "scripts/bootstrap-config.sh"
  "scripts/bootstrap"
  "tests/test_bootstrap"'*'
  "scripts/sweep-unresolved-feedback"
  "tests/test_sweep"'*'
  "tests/test_backfill_unresolved_feedback.sh"
  ".github/workflows/weekly-feedback-sweep.yml"
  "scripts/onepassword-headless-proof-setup.sh"
  ".github/workflows/onepassword-headless-proof.yml"
  "tests/test_sync_overrides.sh"
  "tests/test_eslint_policy_check.sh"
  "tests/test_check_mktemp_portability.sh"
  "tests/test_session_finalization_check.sh"
  "tests/test_check_sync_manifest.sh"
  "tests/test_verify_propagation_pr_templated.sh"
  "scripts/audit-codex-latency.sh"
  "tests/test_audit_codex_latency.sh"
  "tests/fixtures/audit-codex-latency"
  "scripts/audit-review-latency.sh"
  "tests/test_audit_review_latency.sh"
  "scripts/wave-audit.sh"
  "tests/test_wave_audit.sh"
  # Hub-only test harnesses that drive checks (not driven BY them) —
  # not in the manifest, so consumers do not have them.
  "tests/test_ci_scripts_wired.sh"
  "tests/test_repo_lint_consumer_safety.sh"
)

for pat in "${CONSUMER_ABSENT[@]}"; do
  # Expand the glob inside the fixture; nullglob-style via compgen.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    rm -rf "$hit"
  done <<EOF
$(compgen -G "$FIX/$pat" || true)
EOF
done

# A consumer checkout is a plain git repo (several checks run
# git ls-files / git rev-parse --show-toplevel against it).
git -C "$FIX" init -q
# Fail-closed isolation assertion: the fixture repo's toplevel MUST be
# the fixture itself before any add/commit. If a stray gitdir pointer
# survived, abort rather than touch the real repo.
# (pwd -P on both sides: macOS mktemp yields /var/... which git reports
# as the physical /private/var/... path.)
FIX_TOPLEVEL="$(git -C "$FIX" rev-parse --show-toplevel)"
FIX_PHYS="$(cd "$FIX" && pwd -P)"
if [ "$FIX_TOPLEVEL" != "$FIX_PHYS" ]; then
  echo "FATAL: fixture git toplevel is '$FIX_TOPLEVEL', expected '$FIX_PHYS' — refusing to run git writes" >&2
  exit 1
fi
git -C "$FIX" add -A
git -C "$FIX" \
  -c user.name="consumer-fixture" \
  -c user.email="consumer-fixture@example.invalid" \
  -c commit.gpgsign=false \
  commit -qm "consumer fixture"

# Mirror the workflow's make_ci_scripts_executable step.
chmod +x "$FIX"/scripts/ci/*

# ---------------------------------------------------------------------------
# Offline guard: PATH-shimmed gh that fails closed. Hermetic checks
# PATH-shim their own gh stubs (which win by prepending); anything that
# falls through to THIS shim was reaching for live GitHub.
# ---------------------------------------------------------------------------
SHIM="$WORKDIR/shim"
mkdir -p "$SHIM"
cat >"$SHIM/gh" <<'SH'
#!/usr/bin/env bash
echo "test_repo_lint_consumer_safety: live gh call blocked (offline fixture): gh $*" >&2
exit 64
SH
chmod +x "$SHIM/gh"

# ---------------------------------------------------------------------------
# Enumerate the wired checks from the FIXTURE's repo_lint.yml with the
# same awk run-line detection check_ci_scripts_wired uses (comment-only
# mentions do not count; inline `run: |` bodies do not count).
# ---------------------------------------------------------------------------
WIRED=$(awk '
  {
    sub(/[[:space:]]*#.*$/, "")
    if (match($0, /^[[:space:]]*run:[[:space:]]*\.\/scripts\/ci\/check_[A-Za-z0-9_]+/)) {
      line = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*run:[[:space:]]*\.\/scripts\/ci\//, "", line)
      print line
    }
  }
' "$FIX/.github/workflows/repo_lint.yml" | LC_ALL=C sort -u)

if [ -z "$WIRED" ]; then
  fail "no wired checks found in the fixture repo_lint.yml (awk extraction broken?)"
  echo "test_repo_lint_consumer_safety: 0 passed, 1 failed"
  exit 1
fi

WIRED_COUNT=$(printf '%s\n' "$WIRED" | wc -l | tr -d ' ')
echo "test_repo_lint_consumer_safety: running $WIRED_COUNT wired checks against the consumer fixture"

# ---------------------------------------------------------------------------
# Run every wired check from the fixture root; each must exit 0.
# ---------------------------------------------------------------------------
while IFS= read -r name; do
  [ -z "$name" ] && continue
  set +e
  out=$(
    cd "$FIX" && \
    env -u GH_TOKEN -u GITHUB_TOKEN \
        -u OP_PREFLIGHT_REVIEWER_PAT -u OP_PREFLIGHT_AUTHOR_PAT \
        GITHUB_REPOSITORY="nathanjohnpayne/consumer-fixture" \
        PATH="$SHIM:$PATH" \
        bash "./scripts/ci/$name" </dev/null 2>&1
  )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    # Surface whether it PASSed or SKIPped for the log.
    verdict="exit 0"
    echo "$out" | grep -q "SKIP" && verdict="SKIP"
    pass "$name: consumer-safe ($verdict)"
  else
    fail "$name: exit $rc on the consumer fixture — would red every consumer repo-lint. Output tail:"
    echo "$out" | tail -15 >&2
  fi
done <<< "$WIRED"

echo ""
echo "test_repo_lint_consumer_safety: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
