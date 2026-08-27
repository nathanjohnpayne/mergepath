#!/usr/bin/env bash
# tests/test_bootstrap_template_mirror.sh
#
# Validates scripts/bootstrap/template-mirror.sh (sub-B / #204).
# Builds a synthetic mergepath worktree with the documented exclude
# patterns sprinkled around it, runs the wizard's stage B against a
# temp target dir, and asserts:
#
#   1. Every documented exclude path is absent from the target.
#   2. The orphan playground test is removed post-rsync.
#   3. Empty post-rsync dirs (e.g., bugs/) are tombstoned.
#   4. The name-bearing files have their mergepath references
#      substituted to the new repo name in all three case forms
#      (lowercase / Titlecased / UPPERCASE) + URL.
#   4b. Consumer identity is scaffolded neutrally (#744/#747): BRAND.md
#      + docs/agents/repository-overview.md become "downstream consumer"
#      stubs, the hub-only docs are excluded, the AGENTS.md
#      packaging/Repository-Layout section is scrubbed, the README.md
#      hub identity + dead Key-Files rows are scrubbed (#747), and the
#      REVIEW_POLICY.md wave-audit passage is reframed as hub-side
#      machinery (#747), stopping at a hard-wrap continuation line OR a
#      heading with no blank line before it, whichever comes first
#      (round-2 #3662388686).
#   5. .repo-template.yml has the playground spec_test_map entry
#      and extra_top_level_dirs dropped.
#   6. The target has a single initial git commit.
#   7. The cross-repo loop step exits cleanly (with a warning) when
#      the loop-doc anchors are absent. The current mergepath does
#      not carry anchors yet — that's a separate doc-refactor PR.
#
# Requires: rsync, yq, git, awk, sed. (rsync is preinstalled on macOS
# and most Linux distros; yq is checked via the same SKIP pattern as
# the sync test suite.)
#
# Run manually or via scripts/ci/check_bootstrap_template_mirror.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-new-repo.sh"

# --- skip guards ------------------------------------------------------------

if ! command -v rsync >/dev/null 2>&1; then
  echo "SKIP: rsync not installed" >&2
  exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

# --- fixture setup ---------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-template-mirror.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_MP="$WORKDIR/fake-mergepath"
TARGET="$WORKDIR/new-repo"

# Build a synthetic mergepath worktree that mirrors the real repo's
# shape only as much as we need to exercise the stage. Each excluded
# path appears at least once so we can verify it doesn't propagate.
mkdir -p \
  "$FAKE_MP/scripts/bootstrap" \
  "$FAKE_MP/scripts/hooks" \
  "$FAKE_MP/scripts/ci" \
  "$FAKE_MP/scripts/sync" \
  "$FAKE_MP/.github/workflows" \
  "$FAKE_MP/.github/screenshots" \
  "$FAKE_MP/.claude/worktrees" \
  "$FAKE_MP/bugs/screenshots" \
  "$FAKE_MP/dist" \
  "$FAKE_MP/mergepath" \
  "$FAKE_MP/packaging" \
  "$FAKE_MP/tests" \
  "$FAKE_MP/specs" \
  "$FAKE_MP/plans" \
  "$FAKE_MP/docs/agents"

# --- name-bearing files (the substitution targets) ---
# README.md mirrors the real hub README's identity shape (#747): the
# reference-implementation tagline, the BRAND umbrella-vocabulary intro,
# and Key-Files/Directory rows for consumer-excluded surfaces. The
# scaffold step must scrub those AFTER substitution while leaving the
# genuinely-shared rows and prose intact.
cat >"$FAKE_MP/README.md" <<'EOF'
# mergepath

**Reference implementation of the AI Agent Tooling Standard.**

The goal is consistent multi-agent tooling. See [`BRAND.md`](BRAND.md) for the umbrella vocabulary (Playground, Cockpit, Tiebreaker, Checks) and naming history.

A template repo. See https://github.com/nathanjohnpayne/mergepath for the source.

Set `MERGEPATH_ROOT=/path` then run scripts. Mergepath itself is the canonical source.

## Key Files

| File | Purpose |
|---|---|
| `AGENTS.md` | Instructions for AI agents |
| `BRAND.md` | Mergepath umbrella vocabulary (surfaces, reserved names, naming history) |
| `mergepath/playground/index.html` | Mergepath Playground — tune the review policy and replay recent PRs against the draft |
| `scripts/policy-sim.sh` | Bakes real `gh` PR data into a temp copy of the Mergepath Playground for local replay |
| `.mergepath-sync.yml` | Propagation manifest for synced canonical, kit, and templated surfaces |
| `ai_agent_tooling_standard.md` | Full repository standard (reference) |

## Directory Structure

| Directory | Purpose |
|---|---|
| `mergepath/` | Mergepath Playground and reserved slots for future Mergepath surfaces (see `BRAND.md`) |
| `tests/` | Automated validation |
EOF

cat >"$FAKE_MP/BRAND.md" <<'EOF'
# Brand: Mergepath
mergepath, Mergepath, and MERGEPATH all appear here.
EOF

# Hub glossary (#864) — root-level hub-identity doc, excluded outright
# (no consumer stub). Its identity claims are false in a consumer and
# it points at the propagation manifest the mirror strips.
cat >"$FAKE_MP/CONTEXT.md" <<'EOF'
# Mergepath
Mergepath is the reference implementation of the Standard and the hub
of the fleet. See the propagation manifest (.mergepath-sync.yml).
EOF

cat >"$FAKE_MP/.ai_context.md" <<'EOF'
Plain agent context with no template-name string (this file is in
the name-bearing list only so we can test the no-match path).
EOF

cat >"$FAKE_MP/docs/agents/repository-overview.md" <<'EOF'
# mergepath repository overview
This repo (mergepath) is the template. Authors clone from https://github.com/nathanjohnpayne/mergepath.
EOF

cat >"$FAKE_MP/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
  bootstrap_consumer_identity:
    - tests/test_bootstrap_template_mirror.sh
  bootstrap_source_attribution:
    - tests/test_bootstrap_template_mirror.sh
  some_other_spec:
    - tests/test_some_other.sh
test_globs:
  - "tests/**"
extra_top_level_dirs: [mergepath, packaging]
EOF

cat >"$FAKE_MP/SECURITY.md" <<'EOF'
# Security
Report issues to security@mergepath.example.
EOF

# AGENTS.md with the mergepath-only "Repository Layout" / packaging note
# that the #744 scrub must remove in the consumer copy. The Sections
# list carries the #780 reading order: the canonical shared operating
# rules BEFORE the per-repo local overlay.
cat >"$FAKE_MP/AGENTS.md" <<'EOF'
# AGENTS.md

Read the docs before acting.

## Sections

1. **[Shared Agent Operating Rules](docs/agents/shared-operating-rules.md)** --- fleet-wide canonical core
2. **[Agent Operating Rules](docs/agents/operating-rules.md)** --- this repo's local overlay

## Repository Layout

One directory carries its justification here:

- **`packaging/`** --- placeholder package scaffolds that reserve the `mergepath` name on npm and PyPI (name-squatting prevention). See `packaging/README.md`.

## Code Review Policy

Every change goes through REVIEW_POLICY.md.
EOF

# Canonical agent docs (#780) — mirrored verbatim to every new repo,
# and asserted present by bootstrap::_verify_canonical_agent_docs.
echo "# Decision Records (canonical convention)" >"$FAKE_MP/docs/agents/decision-records.md"
echo "# Shared Agent Operating Rules (canonical core)" >"$FAKE_MP/docs/agents/shared-operating-rules.md"
echo "# Worktree Placement (canonical convention)" >"$FAKE_MP/docs/agents/worktree-placement.md"
# The per-repo-owned local overlay it must be read BEFORE.
echo "# Agent Operating Rules (local overlay)" >"$FAKE_MP/docs/agents/operating-rules.md"
# Per-repo-owned deployment instructions are copied verbatim. Seed the
# real document so the fixture proves its banner is truthful in the
# consumer copy too, rather than testing a synthetic neutral sentence.
cp "$ROOT/docs/agents/deployment-process.md" "$FAKE_MP/docs/agents/deployment-process.md"

# REVIEW_POLICY.md with the hub-only wave-audit passage the #747
# reframe must replace in the consumer copy. Deliberately carries NO
# '<!-- bootstrap-loop-list-end -->' anchor, so the cross-repo loop
# step still bails without touching the fixture (assertion 7).
cat >"$FAKE_MP/REVIEW_POLICY.md" <<'EOF'
# AI Agent Code Review Policy

## Overview

Multi-identity review policy body.

### Phase 3.5: Propagation PR review lane

A **propagation PR** — one opened by `scripts/sync-to-downstream.sh` to mirror canonical/kit paths from `mergepath` into a downstream consumer — is a special case of the threshold check.

A lane PR is still subject to CodeRabbit advisory review (on the wave canary; see Wave audit below) and an internal reviewer-identity `APPROVED`.

**Wave audit (#662).** `scripts/wave-audit.sh` dispatches a scoped automated Phase 4b review against the wave canary. Full procedure: `docs/agents/propagation-ordering.md` § Wave audit.

### Phase 4: External Review

Phase 4 body.
EOF

# Hub-only docs (#744) — copied verbatim they describe machinery a
# consumer doesn't run; the mirror must EXCLUDE them.
echo "# The AI Agent Tooling Standard" >"$FAKE_MP/ai_agent_tooling_standard.md"
echo "# Bootstrap runbook (hub-only)" >"$FAKE_MP/docs/agents/bootstrap-runbook.md"
echo "# Propagation ordering (hub-only)" >"$FAKE_MP/docs/agents/propagation-ordering.md"
echo "# Templated propagation (hub-only)" >"$FAKE_MP/docs/agents/templated-propagation.md"
# #780 class audit: the CodeRabbit config audit records the TEMPLATE
# repo's own posture ("our value") and a fleet-wide seat sweep, so it is
# hub-only machinery and must not land in a new repo either.
echo "# CodeRabbit configuration audit (hub-only)" >"$FAKE_MP/docs/agents/coderabbit-audit.md"

# --- excluded paths (must NOT propagate) ---
echo "playground spec" >"$FAKE_MP/specs/mergepath_playground.md"
echo "playground plan" >"$FAKE_MP/plans/mergepath-playground.md"
echo "playground test" >"$FAKE_MP/tests/test_mergepath_playground.sh"
# source-SHA-attribution spec (#1056): must NOT propagate either, since it
# links two hub-only docs/agents/ docs excluded below.
echo "source attribution spec" >"$FAKE_MP/specs/bootstrap_source_attribution.md"
echo "screenshot bug"  >"$FAKE_MP/bugs/screenshots/foo.png"
echo "workflow screen" >"$FAKE_MP/.github/screenshots/bar.png"
echo "claude worktree state" >"$FAKE_MP/.claude/worktrees/foo.json"
echo '{"local":true}' >"$FAKE_MP/.claude/settings.local.json"
echo '{"launch":true}' >"$FAKE_MP/.claude/launch.json"
echo "dist artifact" >"$FAKE_MP/dist/output.tgz"
echo "mergepath internal" >"$FAKE_MP/mergepath/internal.md"
echo "packaging metadata" >"$FAKE_MP/packaging/meta.json"
echo "policy sim" >"$FAKE_MP/scripts/policy-sim.sh"
# #739 canonical-mirror audit pair - hub-only; the mirror must EXCLUDE
# both (shipped to a consumer, the audit's default MERGEPATH_ROOT would
# resolve the CONSUMER checkout as the canonical source). The scripts/ci
# wrapper deliberately stays: the mirrored repo_lint.yml wires it as a
# step, and it consumer-SKIPs via the both-absent marker idiom (asserted
# in 1c below).
echo "canonical-mirror audit (hub-only)" >"$FAKE_MP/scripts/audit-canonical-mirrors.sh"
echo "canonical-mirror audit test (hub-only)" >"$FAKE_MP/tests/test_audit_canonical_mirrors.sh"
# #774 fleet branch-protection audit - hub-only SET (scheduled workflow +
# auditor + both suites). Seeded here so the mirror can be asserted to
# drop all four: the cron reads every sibling repo's protection under an
# admin-scoped fleet secret a new repo does not have, so a bootstrapped
# consumer that carried it would fail the run every Monday forever. The
# scripts/ci wrapper deliberately stays (asserted in 1c below).
echo "protection audit (hub-only)" >"$FAKE_MP/scripts/audit-branch-protection.sh"
echo "protection audit test (hub-only)" >"$FAKE_MP/tests/test_audit_branch_protection.sh"
echo "protection audit workflow test (hub-only)" >"$FAKE_MP/tests/test_audit_branch_protection_workflow.sh"
echo "name: branch-protection-audit" >"$FAKE_MP/.github/workflows/branch-protection-audit.yml"
# Sync-to-downstream orchestrator surface (engine + manifest + paired test +
# cron driver) - mergepath-only; the engine + manifest are also the
# consumer-vs-mergepath markers the propagated scripts/ci/check_* wrappers key
# off, and weekly-drift-audit.yml is the hub-only cron that runs the engine.
# The doc_ownership inventory drives two derivations in the stage:
# bootstrap::_verify_canonical_agent_docs reads `class: canonical`, and
# bootstrap::_derive_hub_only_excludes reads `class: hub-only` to build
# the mirror exclusions. The hub-only entries below are therefore NOT
# decoration — they are what drops the machinery docs created above
# from the mirror, and assertion 4b1 fails without them. They also keep
# the fixture faithful to the real manifest, where every docs/agents
# doc carries exactly one class (check_doc_ownership check 5) and these
# machinery docs carry hub-only.
cat >"$FAKE_MP/.mergepath-sync.yml" <<'EOF'
version: 1
doc_ownership:
  - path: docs/agents/decision-records.md
    class: canonical
  - path: docs/agents/shared-operating-rules.md
    class: canonical
  - path: docs/agents/worktree-placement.md
    class: canonical
  - path: docs/agents/future-rule.md
    class: canonical
    pending_manifest: true
    note: deliberately not required until its backing path lands
  - path: docs/agents/operating-rules.md
    class: per-repo-owned
  - path: docs/agents/deployment-process.md
    class: per-repo-owned
  - path: docs/agents/repository-overview.md
    class: per-repo-owned
  - path: docs/agents/bootstrap-runbook.md
    class: hub-only
  - path: docs/agents/propagation-ordering.md
    class: hub-only
  - path: docs/agents/templated-propagation.md
    class: hub-only
  - path: docs/agents/coderabbit-audit.md
    class: hub-only
EOF
echo "sync engine" >"$FAKE_MP/scripts/sync-to-downstream.sh"
echo "sync engine test" >"$FAKE_MP/tests/test_sync_to_downstream.sh"
echo "name: weekly-drift-audit" >"$FAKE_MP/.github/workflows/weekly-drift-audit.yml"
# Project-doc orchestrator surface (docs/manifest from #509 + engine + test).
echo "version: 1" >"$FAKE_MP/.mergepath-project-docs.yml"
mkdir -p "$FAKE_MP/docs/projects/mergepath/prds"
echo "generated prd mirror" >"$FAKE_MP/docs/projects/mergepath/prds/mergepath.md"
echo "project-doc engine" >"$FAKE_MP/scripts/project-doc-sync.sh"
echo "project-doc test" >"$FAKE_MP/tests/test_project_doc_sync.sh"
# Load-bearing sync internals that MUST still propagate: kit-propagated
# scripts/ci/check_sync_overrides hard-requires tests/test_sync_overrides.sh
# (no consumer-skip path), which sources scripts/sync/. Present here so the
# test can assert they SURVIVE the mirror (excluding them would red lint).
mkdir -p "$FAKE_MP/scripts/sync"
echo "validate overrides" >"$FAKE_MP/scripts/sync/validate-overrides.sh"
echo "apply overrides" >"$FAKE_MP/scripts/sync/apply-overrides.sh"
echo "sync overrides test" >"$FAKE_MP/tests/test_sync_overrides.sh"
echo "old log" >"$FAKE_MP/.bootstrap-log"
echo "old state" >"$FAKE_MP/.bootstrap-state"

# Stash file the bootstrap state file recipe touches.
echo "" >"$FAKE_MP/.claude/.gitkeep"

# --- normal files that SHOULD propagate ---
echo "real script" >"$FAKE_MP/scripts/normal-helper.sh"
echo "real workflow" >"$FAKE_MP/.github/workflows/lint.yml"
# Hub policy with phase_4b_automation ENABLED (#628): the mirror must reset
# the parent switch to false in the target while leaving nested enabled
# keys (accounting) and sibling blocks untouched.
cat >"$FAKE_MP/.github/review-policy.yml" <<'YAML'
coderabbit:
  enabled: true
phase_4b_automation:
  enabled: true
  mode: local
  accounting:
    enabled: true
YAML
echo "real hook" >"$FAKE_MP/scripts/hooks/some-hook.sh"
echo "real ci check" >"$FAKE_MP/scripts/ci/check_thing"

# --- copy the real bootstrap stage files into the fake worktree ---
# Without these, the wizard fails to find its library at startup.
cp "$ROOT/scripts/bootstrap/_lib.sh"                "$FAKE_MP/scripts/bootstrap/_lib.sh"
cp "$ROOT/scripts/bootstrap/template-mirror.sh"     "$FAKE_MP/scripts/bootstrap/template-mirror.sh"
cp "$ROOT/scripts/bootstrap/substitute.sh"          "$FAKE_MP/scripts/bootstrap/substitute.sh"
cp "$ROOT/scripts/bootstrap/github-infra.sh"        "$FAKE_MP/scripts/bootstrap/github-infra.sh"
cp "$ROOT/scripts/bootstrap/firebase-and-codereview.sh" "$FAKE_MP/scripts/bootstrap/firebase-and-codereview.sh"
cp "$ROOT/scripts/bootstrap/board-and-summary.sh"   "$FAKE_MP/scripts/bootstrap/board-and-summary.sh"
cp "$ROOT/scripts/bootstrap-new-repo.sh"            "$FAKE_MP/scripts/bootstrap-new-repo.sh"

# Real consumer-detecting check wrappers - copied so the mirror carries them
# into TARGET (they ride the scripts/ci/ kit in a real bootstrap). The
# consumer-SKIP assertion below runs them FROM the generated TARGET to prove
# they take the skip path now that the orchestrator surface is excluded. They
# are NOT in BOOTSTRAP_NAME_BEARING_FILES, so substitution leaves their
# ".mergepath-sync.yml" / "scripts/sync-to-downstream.sh" detection intact.
cp "$ROOT/scripts/ci/check_sync_manifest"         "$FAKE_MP/scripts/ci/check_sync_manifest"
cp "$ROOT/scripts/ci/check_sync_to_downstream"    "$FAKE_MP/scripts/ci/check_sync_to_downstream"
cp "$ROOT/scripts/ci/check_export_consumer_facts" "$FAKE_MP/scripts/ci/check_export_consumer_facts"
cp "$ROOT/scripts/ci/check_audit_canonical_mirrors" "$FAKE_MP/scripts/ci/check_audit_canonical_mirrors"
cp "$ROOT/scripts/ci/check_branch_protection_audit" "$FAKE_MP/scripts/ci/check_branch_protection_audit"

# git init so preflight check 6 (clean mergepath) passes. The origin remote
# and remote-tracking ref are required for #1056's canonical-source checks
# (bootstrap::_resolve_canonical_source_sha only trusts a source_root's sha
# when its own `origin` names nathanjohnpayne/mergepath AND HEAD is
# contained in a refs/remotes/origin/* ref) -- without both, this fixture
# would exercise the unattributed fallback instead of the sha-attribution
# path it's meant to cover. update-ref stands in for a real fetch/push,
# which this offline fixture never performs.
git -C "$FAKE_MP" init -q
git -C "$FAKE_MP" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture: initial"
git -C "$FAKE_MP" branch -M main 2>/dev/null || true
git -C "$FAKE_MP" update-ref refs/remotes/origin/main HEAD
FAKE_MP_SHA=$(git -C "$FAKE_MP" rev-parse HEAD)

# --- runners --------------------------------------------------------------

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Drive the wizard with stage B in scope. We use the real wizard
# binary so dispatch/preflight integration is exercised end-to-end;
# stages C/D/E remain stubs and run without side effect. The
# environment knobs:
#   BOOTSTRAP_MERGEPATH_ROOT — point source resolution at the fixture
#   BOOTSTRAP_SKIP_TOOL_CHECK=1 — bypass live gh/op probes
#   BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 — fixture is on main+clean by
#     construction but we set this so the test isn't sensitive to
#     the operator's actual mergepath state if the fixture init
#     somehow doesn't go through
#   BOOTSTRAP_AUTO_CONFIRM=1 — auto-yes the cross-repo loop prompt
#     (the function will still short-circuit because anchors absent)
#   BOOTSTRAP_AUTHOR_NAME / EMAIL — make the initial commit
#     reproducible across machines
#
# NOTE: rsync source-root is resolved INSIDE the stage from
# $BOOTSTRAP_MERGEPATH_ROOT, so we point that at the fixture.

set +e
out=$(BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
      BOOTSTRAP_SKIP_TOOL_CHECK=1 \
      BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
      BOOTSTRAP_AUTO_CONFIRM=1 \
      BOOTSTRAP_AUTO_PROMPT=skip \
      BOOTSTRAP_AUTHOR_NAME="test" \
      BOOTSTRAP_AUTHOR_EMAIL="t@t" \
      BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 \
      BOOTSTRAP_SKIP_STAGES="github-infra,firebase-and-codereview,board-and-summary" \
      "$SCRIPT" my-new-repo \
        --target-dir "$TARGET" \
        --description "a test repo" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e

[ "$ec" -eq 0 ] \
  && pass "stage B live run completes (exit 0)" \
  || fail "stage B live run failed; rc=$ec; out: $out"

# --- assertion 1: excludes honored ---
for excluded in \
  '.git' \
  'dist' \
  'mergepath' \
  'packaging' \
  '.claude/worktrees' \
  '.claude/settings.local.json' \
  '.claude/launch.json' \
  'specs/mergepath_playground.md' \
  'plans/mergepath-playground.md' \
  'scripts/policy-sim.sh' \
  'scripts/audit-canonical-mirrors.sh' \
  'tests/test_audit_canonical_mirrors.sh' \
  '.github/workflows/branch-protection-audit.yml' \
  'scripts/audit-branch-protection.sh' \
  'tests/test_audit_branch_protection.sh' \
  'tests/test_audit_branch_protection_workflow.sh' \
  '.mergepath-sync.yml' \
  'scripts/sync-to-downstream.sh' \
  'tests/test_sync_to_downstream.sh' \
  '.github/workflows/weekly-drift-audit.yml' \
  '.mergepath-project-docs.yml' \
  'docs/projects' \
  'scripts/project-doc-sync.sh' \
  'tests/test_project_doc_sync.sh' \
  'CONTEXT.md' \
  'bugs/screenshots' \
  '.github/screenshots' ; do
  # Skip .git — the stage init step creates a fresh .git/ in the target.
  if [ "$excluded" = ".git" ]; then continue; fi
  if [ -e "$TARGET/$excluded" ]; then
    fail "exclude not honored: $excluded ended up at $TARGET/$excluded"
  fi
done
[ "$FAIL" -eq 0 ] && pass "all documented exclude paths honored (incl. sync + project-doc orchestrator surface)"

# --- assertion 1b: load-bearing sync internals MUST survive the mirror ---
# scripts/ci/check_sync_overrides is kit-propagated and has NO consumer-skip
# path - it hard-errors without tests/test_sync_overrides.sh, which sources
# scripts/sync/{validate,apply}-overrides.sh. Excluding any of these would red
# a bootstrapped repo's repo_lint, so they must NOT be swept up with the
# orchestrator surface above.
for kept in \
  'scripts/sync/validate-overrides.sh' \
  'scripts/sync/apply-overrides.sh' \
  'tests/test_sync_overrides.sh' ; do
  [ -e "$TARGET/$kept" ] \
    && pass "load-bearing sync internal propagated: $kept" \
    || fail "$kept must propagate (check_sync_overrides hard-requires it)"
done

# --- assertion 1c: orchestrator checks take the consumer-SKIP path ---
# The point of excluding the surface: the kit-propagated check_* wrappers that
# disambiguate "consumer vs mergepath" must SKIP cleanly (exit 0) when run from
# the generated TARGET, exactly as on a real consumer checkout. Run the REAL
# wrappers (mirrored into TARGET) so this exercises the actual propagated
# detection logic, not a re-implementation:
#   - check_sync_manifest:         .mergepath-sync.yml absent + engine absent
#   - check_sync_to_downstream:    test_sync_to_downstream.sh absent + manifest absent
#   - check_export_consumer_facts: engine absent + manifest absent
#   - check_audit_canonical_mirrors: test_audit_canonical_mirrors.sh absent
#                                    + engine absent (#739 — the wrapper
#                                    ships because repo_lint.yml wires it,
#                                    while its script + test are excluded)
#   - check_branch_protection_audit: both suites absent + engine absent
#                                    (#774 — same shape: the wrapper ships
#                                    because repo_lint.yml wires it, while
#                                    the scheduled workflow, the auditor and
#                                    both suites are excluded)
for chk in check_sync_manifest check_sync_to_downstream check_export_consumer_facts check_audit_canonical_mirrors check_branch_protection_audit; do
  if [ ! -f "$TARGET/scripts/ci/$chk" ]; then
    fail "$chk wrapper did not propagate into TARGET (scripts/ci/ kit)"
    continue
  fi
  set +e
  chk_out=$(bash "$TARGET/scripts/ci/$chk" 2>&1)
  chk_ec=$?
  set -e
  if [ "$chk_ec" -eq 0 ] && printf '%s' "$chk_out" | grep -q "SKIP"; then
    pass "$chk takes consumer-SKIP path on bootstrapped tree"
  else
    fail "$chk should SKIP on bootstrapped tree; rc=$chk_ec, out: $chk_out"
  fi
done

# .bootstrap-log from the source must NOT propagate as-is into the
# target. The wizard creates its OWN .bootstrap-log in the target
# (it's the run transcript), so we assert on CONTENT rather than
# absence: the target's log must not carry the fixture's marker.
if [ -f "$TARGET/.bootstrap-log" ] && grep -q "^old log$" "$TARGET/.bootstrap-log"; then
  fail "old .bootstrap-log content leaked into target (rsync exclude missed it)"
else
  pass "old .bootstrap-log content excluded (target has its own fresh transcript)"
fi
# Same idea for .bootstrap-state.
if [ -f "$TARGET/.bootstrap-state" ] && grep -q "^old state$" "$TARGET/.bootstrap-state"; then
  fail "old .bootstrap-state content leaked into target"
else
  pass "old .bootstrap-state content excluded"
fi

# --- assertion 2: orphan removed ---
[ ! -e "$TARGET/tests/test_mergepath_playground.sh" ] \
  && pass "orphan playground test removed" \
  || fail "tests/test_mergepath_playground.sh should be removed"

# --- assertion 3: empty post-rsync dirs tombstoned ---
[ ! -d "$TARGET/bugs" ] \
  && pass "empty bugs/ dir tombstoned" \
  || fail "bugs/ should be tombstoned after screenshot exclude"

# --- assertion 4: name substitutions ---
grep -q "^# my-new-repo$" "$TARGET/README.md" \
  && pass "README lowercase 'mergepath' substituted" \
  || fail "README didn't get lowercase substitution; got: $(head -1 "$TARGET/README.md")"

# Mergepath URL should become the new repo URL.
grep -q "https://github.com/nathanjohnpayne/my-new-repo" "$TARGET/README.md" \
  && pass "README URL rewritten to new repo" \
  || fail "README URL not rewritten; got: $(grep github "$TARGET/README.md")"

grep -q "^MERGEPATH" "$TARGET/README.md" \
  && fail "uppercase 'MERGEPATH_ROOT' not substituted in README" \
  || pass "uppercase 'MERGEPATH' → 'MY_NEW_REPO' substituted"
grep -q "MY_NEW_REPO_ROOT" "$TARGET/README.md" \
  && pass "uppercase env-var form 'MY_NEW_REPO_ROOT' present" \
  || fail "expected 'MY_NEW_REPO_ROOT' in README; got: $(grep _ROOT "$TARGET/README.md")"

# BRAND.md + repository-overview.md are SCAFFOLDED as neutral consumer
# stubs (#744), NOT substituted from mergepath's identity narrative.
grep -q "downstream consumer of the \[mergepath\]" "$TARGET/BRAND.md" \
  && pass "BRAND.md scaffolded with neutral consumer framing (#744)" \
  || fail "BRAND.md not scaffolded; got: $(head -3 "$TARGET/BRAND.md")"
grep -q "My-new-repo is not" "$TARGET/BRAND.md" \
  && pass "BRAND.md disclaims reference-implementation status" \
  || fail "BRAND.md missing the 'is not the reference impl' disclaimer"
grep -qi "Playground\|Cockpit\|Tiebreaker" "$TARGET/BRAND.md" \
  && fail "BRAND.md still carries mergepath's Playground/Cockpit surfaces" \
  || pass "BRAND.md dropped the mergepath surface list"
# The fixture BRAND.md content ("Brand: Mergepath") must NOT survive.
grep -q "Brand: My-new-repo\|Brand: Mergepath" "$TARGET/BRAND.md" \
  && fail "BRAND.md still carries the substituted fixture content" \
  || pass "BRAND.md fixture content replaced by the scaffold"
grep -q "downstream \*\*consumer\*\* of the \[mergepath\]" "$TARGET/docs/agents/repository-overview.md" \
  && pass "repository-overview.md scaffolded with neutral consumer framing (#744)" \
  || fail "repository-overview.md not scaffolded; got: $(head -3 "$TARGET/docs/agents/repository-overview.md")"
if grep -q "mergepath's own" "$TARGET/docs/agents/deployment-process.md"; then
  fail "deployment-process.md copied mergepath-only ownership prose into the consumer"
elif grep -q "repository carrying this copy" "$TARGET/docs/agents/deployment-process.md"; then
  pass "deployment-process.md keeps repo-owned deployment prose consumer-neutral"
else
  fail "deployment-process.md lost the repo-owned banner while being mirrored"
fi

# No residual 'mergepath' in the STILL-SUBSTITUTED name-bearing files.
# BRAND.md + repository-overview.md are excluded here: their scaffolds
# intentionally reference the mergepath hub (URL + "mergepath is the
# reference implementation"). Since #747, README.md carries exactly ONE
# intentional hub reference too — the scaffold-written tagline — so it
# is checked with that line filtered out rather than blanket-excluded.
remaining=$(grep -h -i "mergepath" "$TARGET/SECURITY.md" 2>/dev/null || true)
[ -z "$remaining" ] \
  && pass "no residual 'mergepath' references in substituted name-bearing files" \
  || fail "residual 'mergepath' references found: $remaining"
readme_residual=$(grep -i "mergepath" "$TARGET/README.md" 2>/dev/null \
  | grep -vF "downstream consumer of the [mergepath](https://github.com/nathanjohnpayne/mergepath)" || true)
[ -z "$readme_residual" ] \
  && pass "README.md's only 'mergepath' reference is the intentional hub tagline (#747)" \
  || fail "unexpected 'mergepath' references in README.md: $readme_residual"

# --- assertion 4b: hub-only MACHINERY docs excluded (#744) ---
hub_leak=""
for d in docs/agents/bootstrap-runbook.md \
         docs/agents/propagation-ordering.md docs/agents/templated-propagation.md \
         docs/agents/coderabbit-audit.md; do
  [ -e "$TARGET/$d" ] && hub_leak="$hub_leak $d"
done
[ -z "$hub_leak" ] \
  && pass "hub-only machinery docs excluded from the consumer mirror (#744)" \
  || fail "hub-only machinery docs leaked into consumer:$hub_leak"
# ai_agent_tooling_standard.md is the methodology-neutral Standard the
# consumer follows (not machinery, not name-substituted) — it must be
# KEPT so README.md / .ai_context.md links stay live (Codex #746).
[ -f "$TARGET/ai_agent_tooling_standard.md" ] \
  && pass "ai_agent_tooling_standard.md kept in the consumer (Standard, not machinery)" \
  || fail "ai_agent_tooling_standard.md was wrongly excluded from the consumer"

# --- assertion 4b2: every PROSE statement of the exclusion set is whole -
# Two live documents enumerate the docs/agents/ mirror exclusions:
# specs/bootstrap_consumer_identity.md (the ground-truth acceptance
# criteria, whose preservation boundary reads "everything not named
# above flows through the mirror untouched") and
# docs/agents/bootstrap-runbook.md step 5 (the operator runbook read
# while actually running the wizard). A docs/agents/ path added to
# BOOTSTRAP_MIRROR_EXCLUDES without a matching entry in BOTH therefore
# makes a live document state the opposite of what the code does — which
# is exactly what happened when coderabbit-audit.md was added while both
# the spec and the runbook still enumerated only the original three
# machinery docs (#797 review). An operator trusting the runbook writes
# a consumer-side doc linking a file the mirror never delivered, and the
# link 404s.
#
# Read the exclude set from the implementation rather than restating
# it: a second hard-coded copy is the drift this guard exists to catch.
#
# The mirror now drops a docs/agents/ file by one of TWO routes, so the
# set this compares against prose is the UNION of both. Checking only
# the array would have quietly narrowed this guard to
# repository-overview.md the moment the hub-only docs moved out of it:
#
#   * BOOTSTRAP_MIRROR_EXCLUDES — what the inventory does not imply
#     (docs/agents/repository-overview.md, excluded while staying
#     per-repo-owned).
#   * doc_ownership's `class: hub-only` entries — derived into
#     exclusions at rsync time by
#     bootstrap::_derive_hub_only_excludes.
#
# Each side must yield something; an empty derivation means the shape
# it reads has moved and this guard has gone blind, which fails rather
# than passes.
MIRROR_LIB="$ROOT/scripts/bootstrap/template-mirror.sh"
LIVE_MANIFEST="$ROOT/.mergepath-sync.yml"
EXCLUSION_PROSE_SURFACES=(
  specs/bootstrap_consumer_identity.md
  docs/agents/bootstrap-runbook.md
)
if [ -f "$MIRROR_LIB" ]; then
  array_docs=$(awk '
    /^BOOTSTRAP_MIRROR_EXCLUDES=\(/ { inside = 1; next }
    inside && /^\)/                 { inside = 0 }
    inside                          { print }
  ' "$MIRROR_LIB" \
    | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^'//; s/'\$//" \
    | grep -E '^docs/agents/.+\.md$' || true)
  hub_only_docs=$(yq -r '.doc_ownership[] | select(.class == "hub-only") | .path' "$LIVE_MANIFEST" 2>/dev/null || true)
  if [ -z "$array_docs" ]; then
    fail "could not read any docs/agents/ entry out of BOOTSTRAP_MIRROR_EXCLUDES — the array shape changed and this guard is now blind"
    excluded_docs=""
  elif [ -z "$hub_only_docs" ]; then
    fail "could not derive any 'class: hub-only' doc from $LIVE_MANIFEST — the class name moved and this guard is now blind"
    excluded_docs=""
  else
    excluded_docs=$(printf '%s\n%s\n' "$array_docs" "$hub_only_docs" | grep -v '^$' | LC_ALL=C sort -u)
  fi
  if [ -z "$excluded_docs" ]; then
    :
  else
    for surface in "${EXCLUSION_PROSE_SURFACES[@]}"; do
      if [ ! -f "$ROOT/$surface" ]; then
        fail "exclusion-set prose surface missing: $surface"
        continue
      fi
      prose_gap=""
      while IFS= read -r excluded; do
        [ -n "$excluded" ] || continue
        grep -qF -- "$excluded" "$ROOT/$surface" || prose_gap="$prose_gap $excluded"
      done <<< "$excluded_docs"
      [ -z "$prose_gap" ] \
        && pass "$surface names every docs/agents/ mirror exclusion" \
        || fail "$surface does not name every docs/agents doc BOOTSTRAP_MIRROR_EXCLUDES drops (update its enumeration):$prose_gap"
    done
  fi
fi

# --- assertion 4b3: no hard-coded count of the hub-only doc set -------
# The exclusion set has already grown once (#780 added a fourth
# machinery doc) and every prose restatement of its SIZE went stale in
# place: the runbook's step 5, both step-5b comments in
# template-mirror.sh, and the tell-(b) scanner comment in
# tests/test_check_sync_manifest.sh all kept asserting the old number
# after the new doc landed. A count is unmaintainable by construction —
# assertion 4b2 can mechanically verify an ENUMERATION against the
# implementation, but nothing can verify a number written in prose. So
# the convention is simply: never write one. Name the source of truth
# (BOOTSTRAP_MIRROR_EXCLUDES, or the manifest's `class: hub-only`
# entries) and let the enumeration guard do the rest.
#
# The scan must be WRAP-INSENSITIVE. Shell comments in
# template-mirror.sh are hard-wrapped near 72 columns by local
# convention, and the first cut of this guard was a single-line regex.
# It caught the step-5b dispatch comment, where the stale claim happened
# to fit on one line, and sailed straight past the identical claim in
# the bootstrap::_scaffold_consumer_identity header, where the natural
# wrap fell between "and the" and the count opening the next line — so
# the guard was vacuous for one of the two comments it was written to
# protect, and re-wording that header back would have reintroduced the
# defect with CI fully green. Re-wrapping a comment must never change
# what a guard sees, so each candidate file is flattened into
# whitespace-normalised blocks first and the phrases are matched against
# those.
#
# Neither pattern hard-codes the CURRENT size: a count is banned
# whatever its value, because a stale number (three) has to fail just as
# loudly as a fresh one (four). What IS derived is the region and the
# file list — a fifth exclusion needs no edit here.
#
# Scope, stated plainly rather than implied: both patterns are
# determiner-led. A BARE cardinal in front of the token — "two hub-only
# docs cross-referencing each other" in tests/test_check_doc_ownership.sh
# — is deliberately allowed, because that sentence counts a synthetic
# two-doc fixture it defines two lines later, not this set, and banning
# the shape would only teach the next author to reword around the guard.
# Nor does either pattern read a count that trails its subject
# ("the hub-only docs, all four of them"). What they do cover is the
# shape every stale statement so far has taken: a determiner, a count,
# and the subject, in that order, at any wrapping.

# Scan $1 for the ERE in $2 over wrap-insensitive blocks. A block is a
# maximal run of consecutive non-blank lines; each line is stripped of
# leading whitespace and of a leading comment/list marker, its interior
# whitespace is collapsed, and the lines are joined with single spaces —
# so a phrase broken by a hard wrap still reads as one string. Every
# match prints "<line>: <bounded snippet>", mapping the offset inside
# the joined block back to the physical line the match starts on, so the
# report stays as actionable as a plain `grep -n`. $3/$4 optionally
# restrict the scan to a line range.
mirror_scan_wrapped() {
  awk -v pat="$2" -v from="${3:-1}" -v to="${4:-0}" '
    function flush(   probe, pos, abs, i, ln, s) {
      if (buf == "") return
      # Prepend a space so a phrase at offset 1 still has a left
      # boundary character: the patterns can then require a real
      # non-word char rather than offering "^" as an alternative, which
      # would match falsely when rescanning the tail after a hit.
      probe = " " buf
      pos = 1
      while (match(substr(probe, pos), pat)) {
        abs = pos + RSTART - 1
        ln = start
        for (i = 1; i <= n; i++) if (offs[i] <= abs) ln = lns[i]
        s = abs - 40; if (s < 1) s = 1
        print ln ": " substr(buf, s, RLENGTH + 80)
        pos = abs + RLENGTH
      }
      buf = ""; n = 0
    }
    NR < from { next }
    to > 0 && NR > to { flush(); exit }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/^(#+|\/\/|\*|-|>)[[:space:]]*/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/ $/, "", line)
      if (line == "") { flush(); next }
      if (buf == "") { start = NR; buf = line; n = 1; offs[1] = 1; lns[1] = NR }
      else { n++; offs[n] = length(buf) + 2; lns[n] = NR; buf = buf " " line }
    }
    END { flush() }
  ' "$1"
}

if ! command -v git >/dev/null 2>&1 \
   || ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Fail closed, like 4b2's empty-derivation branch and Case 37's empty
  # alternation. This suite already requires git (assertion 6 asserts
  # the bootstrapped target's initial commit), so a missing checkout is
  # a broken environment rather than a supported mode — and a guard that
  # silently skips is how a stale count gets back in unnoticed.
  fail "assertion 4b3 cannot enumerate tracked files (git or a git checkout at $ROOT is unavailable), so the hard-coded-count scan would be blind — failing closed instead of skipping"
elif [ ! -f "$MIRROR_LIB" ]; then
  fail "assertion 4b3 cannot read $MIRROR_LIB — the array-scoped count scan is blind"
else
  # Vocabulary, assembled from parts at runtime so this guard does not
  # match its own source text.
  count_alt='one|two|three|four|five|six|seven|eight|nine|ten|10|[1-9]'
  det_alt='the|these|those|all|its'

  # (a) Repo-wide: a determiner + cardinal in front of the set's name
  #     ("... and the <count> hub-only docs", "all <count> of the
  #     hub-only docs"), in any wrapping. `hub-only` is the trailing
  #     anchor, so `git grep -l` on that literal is a sound superset
  #     pre-filter for the file list — a match cannot exist in a file
  #     that never spells the token.
  count_re="[^[:alnum:]_-](${det_alt})[[:space:]]+(${count_alt})[[:space:]]+(of[[:space:]]+(the[[:space:]]+)?)?hub-only"
  count_files=$(git -C "$ROOT" grep -lI 'hub-only' -- . || true)
  if [ -z "$count_files" ]; then
    fail "assertion 4b3 found no tracked file containing the literal 'hub-only' — the anchor token moved and this scan is now blind"
  else
    count_prose=""
    while IFS= read -r count_file; do
      [ -n "$count_file" ] || continue
      count_file_hits=$(mirror_scan_wrapped "$ROOT/$count_file" "$count_re" || true)
      if [ -n "$count_file_hits" ]; then
        count_prose="$count_prose
$(printf '%s\n' "$count_file_hits" | sed -E "s|^|  $count_file:|")"
      fi
    done <<< "$count_files"
    [ -z "$count_prose" ] \
      && pass "no tracked file hard-codes a count of the hub-only doc set (wrap-insensitive)" \
      || fail "hard-coded hub-only doc count(s) found — name BOOTSTRAP_MIRROR_EXCLUDES or the manifest's class: hub-only entries instead of a number:$count_prose"
  fi

  # (b) Array-scoped: inside BOOTSTRAP_MIRROR_EXCLUDES' own commentary a
  #     demonstrative or definite article + cardinal states the size of
  #     the array it sits in whatever noun follows, so (a)'s trailing
  #     anchor never sees it — "the only one of these four whose absence
  #     ..." named no set at all and shipped one line above the entries
  #     it miscounted (#797 review). The extent scanned is DERIVED from
  #     the array header and its closing paren, not a line range, and
  #     the scan fails closed if either end cannot be located.
  arr_start=$(awk '/^BOOTSTRAP_MIRROR_EXCLUDES=\(/ { print NR; exit }' "$MIRROR_LIB")
  arr_end=$(awk -v s="${arr_start:-0}" 's > 0 && NR > s && /^\)/ { print NR; exit }' "$MIRROR_LIB")
  if [ -z "$arr_start" ] || [ -z "$arr_end" ]; then
    fail "could not locate the BOOTSTRAP_MIRROR_EXCLUDES body in $MIRROR_LIB (header=${arr_start:-?}, close=${arr_end:-?}) — assertion 4b3's array-scoped count scan is blind"
  else
    arr_count_re="[^[:alnum:]_-](the|these|those)[[:space:]]+(${count_alt})([^[:alnum:]_-]|$)"
    arr_count_prose=$(mirror_scan_wrapped "$MIRROR_LIB" "$arr_count_re" "$arr_start" "$arr_end" \
      | sed -E "s|^|  ${MIRROR_LIB#"$ROOT/"}:|" || true)
    [ -z "$arr_count_prose" ] \
      && pass "BOOTSTRAP_MIRROR_EXCLUDES' own commentary states no count of the set it lists" \
      || fail "BOOTSTRAP_MIRROR_EXCLUDES' commentary hard-codes the size of the set it lists — refer to the entries below it instead of counting them:
$arr_count_prose"
  fi
fi

# --- assertion 4b4: hub-only exclusions are DERIVED, not restated -----
# `doc_ownership:` and BOOTSTRAP_MIRROR_EXCLUDES used to be two
# hand-maintained lists that had to agree, and classifying the next doc
# hub-only without also editing the array would have rsynced hub-only
# content into the next new repo (#797 review). The array no longer
# carries those paths at all: bootstrap::_derive_hub_only_excludes
# reads `class: hub-only` out of the SOURCE manifest on every run and
# bootstrap::_rsync_template appends the result to the rsync patterns,
# so the inventory is the only place the set is written down and the
# two cannot disagree.
#
# That makes the old "do the lists agree?" comparison meaningless — it
# would be asserting a property of one list against itself. What has to
# be proven instead is that the derivation actually happens, covers the
# inventory, and fails CLOSED. A derivation that silently yields
# nothing is worse than the hand-maintained array it replaced, because
# rsync with no hub-only excludes copies every one of them.
#
# Note this asserts nothing about the REVERSE containment: BRAND.md and
# docs/agents/repository-overview.md are excluded via the array while
# staying per-repo-owned, so the excluded set stays a superset of the
# hub-only set by design.

# Call bootstrap::_derive_hub_only_excludes against a synthetic source
# root, with the logging helpers stubbed the way verify_case does.
# Sets DERIVE_RC / DERIVE_OUT / DERIVE_ERR.
#
# stdout and stderr are captured SEPARATELY, and the bootstrap::err
# stub writes to stderr exactly as scripts/bootstrap/_lib.sh does. That
# fidelity is load-bearing rather than tidiness: the caller consumes
# this function's stdout as the exclude-pattern list, so a stub that
# echoed diagnostics to stdout would model a tool that cannot exist and
# would hide the failure mode where an error message becomes an rsync
# --exclude argument.
derive_case() {
  # $1 = mutation applied inside a copy of the fixture source root
  local mutate="${1:-:}" source rc
  source="$(mktemp -d "$WORKDIR/derive-source.XXXXXX")"
  cp "$FAKE_MP/.mergepath-sync.yml" "$source/.mergepath-sync.yml"
  ( cd "$source" && eval "$mutate" )
  set +e
  bash -c '
    bootstrap::log() { :; }
    bootstrap::err() { echo "ERR: $*" >&2; }
    source "$1"
    bootstrap::_derive_hub_only_excludes "$2"
  ' _ "$MIRROR_LIB" "$source" >"$WORKDIR/derive.out" 2>"$WORKDIR/derive.err"
  rc=$?
  set -e
  DERIVE_RC=$rc
  DERIVE_OUT=$(cat "$WORKDIR/derive.out")
  DERIVE_ERR=$(cat "$WORKDIR/derive.err")
}

# Control: the fixture's hub-only entries come back, in full, on stdout
# and with nothing on stderr.
derive_case
expected_derived=$(yq -r '.doc_ownership[] | select(.class == "hub-only") | .path' "$FAKE_MP/.mergepath-sync.yml" | LC_ALL=C sort)
actual_derived=$(printf '%s\n' "$DERIVE_OUT" | grep -v '^$' | LC_ALL=C sort || true)
if [ "$DERIVE_RC" = "0" ] && [ -n "$expected_derived" ] && [ "$actual_derived" = "$expected_derived" ] && [ -z "$DERIVE_ERR" ]; then
  pass "hub-only mirror exclusions are derived from the source manifest's doc_ownership (#797 review)"
else
  fail "derivation did not return the manifest's hub-only set (rc=$DERIVE_RC, stderr='$DERIVE_ERR'); expected:
$expected_derived
got:
$actual_derived"
fi

# check_doc_ownership accepts leading './' spellings after normalizing
# them to repo-relative paths. The bootstrap derivation consumes the
# same inventory, so it must accept and emit that same normalized set.
derive_case 'yq -i '\''(.doc_ownership[] | select(.class == "hub-only") | .path) |= "./" + .'\'' .mergepath-sync.yml'
normalized_expected=$(printf '%s\n' "$expected_derived" | sed 's#^\./##' | LC_ALL=C sort)
normalized_actual=$(printf '%s\n' "$DERIVE_OUT" | grep -v '^$' | LC_ALL=C sort || true)
if [ "$DERIVE_RC" = "0" ] && [ "$normalized_actual" = "$normalized_expected" ] && [ -z "$DERIVE_ERR" ]; then
  pass "hub-only mirror derivation accepts and normalizes './' ownership paths"
else
  fail "derivation disagrees with doc_ownership path normalization (rc=$DERIVE_RC, stderr='$DERIVE_ERR'); expected:
$normalized_expected
got:
$normalized_actual"
fi

# The finding's exact scenario: classify one more doc hub-only and touch
# NOTHING else. Under the old hand-maintained array this leaked; the
# derived set has to pick it up with no code edit at all.
derive_case 'yq -i '\''.doc_ownership += [{"path":"docs/agents/newly-hub-only.md","class":"hub-only"}]'\'' .mergepath-sync.yml'
if [ "$DERIVE_RC" = "0" ] && printf '%s\n' "$DERIVE_OUT" | grep -qx 'docs/agents/newly-hub-only.md'; then
  pass "a newly classified hub-only doc is excluded with no edit to BOOTSTRAP_MIRROR_EXCLUDES (#797 review)"
else
  fail "derivation missed a newly classified hub-only doc (rc=$DERIVE_RC): $DERIVE_OUT $DERIVE_ERR"
fi
# ... and the array genuinely does not name it, so the line above cannot
# be passing for the old reason.
if grep -qF 'docs/agents/newly-hub-only.md' "$MIRROR_LIB"; then
  fail "BOOTSTRAP_MIRROR_EXCLUDES names the synthetic doc — the assertion above proves nothing"
else
  pass "the synthetic hub-only doc appears nowhere in $MIRROR_LIB (derivation, not restatement)"
fi

# Fail-closed branches. Each must return non-zero AND say why; a
# derivation that returns 0 with an empty set would mirror hub-only
# content into the new repo silently, which is the whole hazard.
derive_case 'rm .mergepath-sync.yml'
if [ "$DERIVE_RC" != "0" ] && printf '%s' "$DERIVE_ERR" | grep -q 'source .mergepath-sync.yml missing'; then
  pass "derivation fails closed when the source manifest is absent"
else
  fail "derivation should fail closed without a source manifest (rc=$DERIVE_RC): $DERIVE_ERR"
fi

derive_case 'printf "version: 1\n" > .mergepath-sync.yml'
if [ "$DERIVE_RC" != "0" ] && printf '%s' "$DERIVE_ERR" | grep -q 'no valid doc_ownership list'; then
  pass "derivation fails closed when doc_ownership is absent"
else
  fail "derivation should fail closed without a doc_ownership list (rc=$DERIVE_RC): $DERIVE_ERR"
fi

derive_case 'printf "doc_ownership:\n  - path: docs/agents/x.md\n    class: canonical\n" > .mergepath-sync.yml'
if [ "$DERIVE_RC" != "0" ] && printf '%s' "$DERIVE_ERR" | grep -q 'no .class: hub-only. doc'; then
  pass "derivation fails closed when the inventory yields no hub-only doc (the class name moved)"
else
  fail "derivation should refuse an empty hub-only set (rc=$DERIVE_RC): $DERIVE_ERR"
fi

# A wildcard would be honored by rsync: `docs/agents/*.md` strips every
# canonical agent doc from the new repo. Reject it at the source.
derive_case 'yq -i '\''.doc_ownership += [{"path":"docs/agents/*.md","class":"hub-only"}]'\'' .mergepath-sync.yml'
if [ "$DERIVE_RC" != "0" ] && printf '%s' "$DERIVE_ERR" | grep -q 'wildcard metacharacter'; then
  pass "derivation rejects a wildcard hub-only path before it reaches rsync"
else
  fail "derivation should reject a wildcard hub-only path (rc=$DERIVE_RC): $DERIVE_ERR"
fi
# ...and it emits NOTHING on the way out. The rejected entry is appended
# AFTER the fixture's valid hub-only paths, so a function that streamed
# each path as it validated it would have already written those valid
# ones to stdout before reaching the bad one. A caller reading stdout
# would then mirror with a partial exclusion set. Diagnostics go to
# stderr and the path list is buffered until the whole inventory checks
# out, so a failed derivation yields no patterns at all.
[ -z "$DERIVE_OUT" ] \
  && pass "a rejected derivation emits no partial exclude list on stdout" \
  || fail "a rejected derivation left patterns on stdout that a caller could mirror with: $DERIVE_OUT"

derive_case 'yq -i '\''.doc_ownership += [{"path":"scripts/secret.sh","class":"hub-only"}]'\'' .mergepath-sync.yml'
if [ "$DERIVE_RC" != "0" ] && printf '%s' "$DERIVE_ERR" | grep -q "only for 'docs/agents/\*\.md' paths"; then
  pass "derivation fails closed on a hub-only path outside the inventory's documented scope"
else
  fail "derivation should refuse an out-of-scope hub-only path (rc=$DERIVE_RC): $DERIVE_ERR"
fi

# --- assertion 4b5: the derivation is actually WIRED into the rsync ---
# Everything above tests the helper. This drives
# bootstrap::_rsync_template end to end against a miniature source tree
# whose manifest classifies a doc hub-only that BOOTSTRAP_MIRROR_EXCLUDES
# has never heard of, and asserts the file does not land — the property
# an operator actually depends on. A helper that derives perfectly but
# is never called would pass every assertion above and still leak.
rsync_src="$(mktemp -d "$WORKDIR/rsync-src.XXXXXX")"
rsync_dst="$(mktemp -d "$WORKDIR/rsync-dst.XXXXXX")"
mkdir -p "$rsync_src/docs/agents" "$rsync_dst/docs/agents"
printf 'hub only\n'  > "$rsync_src/docs/agents/newly-hub-only.md"
printf 'canonical\n' > "$rsync_src/docs/agents/decision-records.md"
printf 'readme\n'    > "$rsync_src/README.md"
# Reproduce a resumed Stage B after this path changed from mirrored to
# hub-only: rsync exclusion prevents a fresh copy but does not delete this
# receiver-side residue on its own.
printf 'stale copy from interrupted bootstrap\n' > "$rsync_dst/docs/agents/newly-hub-only.md"
cat >"$rsync_src/.mergepath-sync.yml" <<'YAML'
version: 1
doc_ownership:
  - path: docs/agents/decision-records.md
    class: canonical
  - path: docs/agents/newly-hub-only.md
    class: hub-only
YAML
set +e
rsync_out=$(bash -c '
  bootstrap::log() { :; }
  bootstrap::err() { echo "ERR: $*" >&2; }
  bootstrap::run() { local label=$1; shift; "$@"; }
  source "$1"
  bootstrap::_rsync_template "$2" "$3"
' _ "$MIRROR_LIB" "$rsync_src" "$rsync_dst" 2>&1)
rsync_rc=$?
set -e
if [ "$rsync_rc" != "0" ]; then
  fail "end-to-end rsync with a derived hub-only exclude failed (rc=$rsync_rc): $rsync_out"
else
  if [ -e "$rsync_dst/docs/agents/newly-hub-only.md" ]; then
    fail "a 'class: hub-only' doc that BOOTSTRAP_MIRROR_EXCLUDES never names was copied into the mirror — the derivation is not wired into bootstrap::_rsync_template"
  else
    pass "bootstrap::_rsync_template removes a stale, newly hub-only doc on resume (#797 review)"
  fi
  [ -f "$rsync_dst/docs/agents/decision-records.md" ] && [ -f "$rsync_dst/README.md" ] \
    && pass "the derived exclude is scoped: canonical docs and ordinary files still mirror" \
    || fail "the derived exclude over-matched — canonical/ordinary files missing from the mirror"
fi

# A target subdirectory may be a symlink even when the target root itself is
# legitimate. Removing receiver residue through that path would unlink a file
# outside the bootstrap target before rsync has a chance to replace the link.
symlink_dst="$(mktemp -d "$WORKDIR/symlink-dst.XXXXXX")"
symlink_outside="$(mktemp -d "$WORKDIR/symlink-outside.XXXXXX")"
mkdir -p "$symlink_dst/docs"
printf 'must survive bootstrap\n' > "$symlink_outside/newly-hub-only.md"
ln -s "$symlink_outside" "$symlink_dst/docs/agents"
set +e
symlink_rsync_out=$(bash -c '
  bootstrap::log() { :; }
  bootstrap::err() { echo "ERR: $*" >&2; }
  bootstrap::run() { local label=$1; shift; "$@"; }
  source "$1"
  bootstrap::_rsync_template "$2" "$3"
' _ "$MIRROR_LIB" "$rsync_src" "$symlink_dst" 2>&1)
symlink_rsync_rc=$?
set -e
if [ "$symlink_rsync_rc" != "0" ] \
   && [ -f "$symlink_outside/newly-hub-only.md" ] \
   && printf '%s' "$symlink_rsync_out" | grep -q 'symlink ancestor'; then
  pass "bootstrap::_rsync_template rejects a symlink ancestor without deleting outside the target"
else
  fail "symlinked target ancestry must fail closed and preserve the outside file (rc=$symlink_rsync_rc): $symlink_rsync_out"
fi

# The selected target itself can also be a symlink. Check it before appending
# even the first relative component, or stale-residue deletion escapes through
# the root link.
root_symlink_outside="$(mktemp -d "$WORKDIR/root-symlink-outside.XXXXXX")"
root_symlink_dst="$WORKDIR/root-symlink-target"
mkdir -p "$root_symlink_outside/docs/agents"
printf 'must survive root symlink\n' > "$root_symlink_outside/docs/agents/newly-hub-only.md"
ln -s "$root_symlink_outside" "$root_symlink_dst"
set +e
root_symlink_out=$(bash -c '
  bootstrap::log() { :; }
  bootstrap::err() { echo "ERR: $*" >&2; }
  bootstrap::run() { local label=$1; shift; "$@"; }
  source "$1"
  bootstrap::_rsync_template "$2" "$3"
' _ "$MIRROR_LIB" "$rsync_src" "$root_symlink_dst" 2>&1)
root_symlink_rc=$?
set -e
if [ "$root_symlink_rc" != "0" ] \
   && [ -f "$root_symlink_outside/docs/agents/newly-hub-only.md" ] \
   && printf '%s' "$root_symlink_out" | grep -q 'target root.*symbolic link'; then
  pass "bootstrap::_rsync_template rejects a symlinked target root without deleting outside it"
else
  fail "symlinked target root must fail closed and preserve the outside file (rc=$root_symlink_rc): $root_symlink_out"
fi

# An existing directory at a path that has become hub-only cannot be removed
# with `rm -f`. `_rsync_template` may run in a conditional/`||` context where
# Bash disables errexit inside the function, so the helper must propagate the
# failed removal explicitly instead of continuing to an excluding rsync that
# returns success and leaves the residue behind.
remove_fail_dst="$(mktemp -d "$WORKDIR/remove-fail-dst.XXXXXX")"
mkdir -p "$remove_fail_dst/docs/agents/newly-hub-only.md"
set +e
remove_fail_out=$(bash -c '
  bootstrap::log() { :; }
  bootstrap::err() { echo "ERR: $*" >&2; }
  bootstrap::run() { local label=$1; shift; "$@"; }
  source "$1"
  stage_rc=0
  bootstrap::_rsync_template "$2" "$3" || stage_rc=$?
  exit "$stage_rc"
' _ "$MIRROR_LIB" "$rsync_src" "$remove_fail_dst" 2>&1)
remove_fail_rc=$?
set -e
if [ "$remove_fail_rc" != "0" ] \
   && [ -d "$remove_fail_dst/docs/agents/newly-hub-only.md" ]; then
  pass "bootstrap::_rsync_template propagates a stale-document removal failure"
else
  fail "failed stale-document removal must abort before rsync (rc=$remove_fail_rc): $remove_fail_out"
fi

# And the wiring fails closed: an unreadable inventory must abort the
# rsync rather than mirror everything. Assert the destination stays
# EMPTY, not merely that the rc is non-zero — "it errored" and "it
# copied nothing" are different claims, and only the second is the one
# that keeps hub-only content out of the new repo.
blind_src="$(mktemp -d "$WORKDIR/blind-src.XXXXXX")"
blind_dst="$(mktemp -d "$WORKDIR/blind-dst.XXXXXX")"
mkdir -p "$blind_src/docs/agents"
printf 'hub only\n' > "$blind_src/docs/agents/some-machinery.md"
printf 'version: 1\n' > "$blind_src/.mergepath-sync.yml"
set +e
blind_rsync_out=$(bash -c '
  bootstrap::log() { :; }
  bootstrap::err() { echo "ERR: $*" >&2; }
  bootstrap::run() { local label=$1; shift; "$@"; }
  source "$1"
  bootstrap::_rsync_template "$2" "$3"
' _ "$MIRROR_LIB" "$blind_src" "$blind_dst" 2>&1)
blind_rsync_rc=$?
set -e
blind_copied=$(find "$blind_dst" -type f | head -1)
if [ "$blind_rsync_rc" != "0" ] && [ -z "$blind_copied" ] \
   && printf '%s' "$blind_rsync_out" | grep -q 'refusing to rsync without the hub-only exclusions'; then
  pass "bootstrap::_rsync_template aborts, copying nothing, when the hub-only exclusions cannot be derived"
else
  fail "rsync should abort with an empty destination on an underivable inventory (rc=$blind_rsync_rc, copied='$blind_copied'): $blind_rsync_out"
fi

# --- assertion 4c: AGENTS.md packaging/Repository-Layout scrub (#744) ---
if [ -f "$TARGET/AGENTS.md" ]; then
  grep -q "placeholder package scaffolds that reserve" "$TARGET/AGENTS.md" \
    && fail "AGENTS.md still documents the mergepath-only packaging/ dir" \
    || pass "AGENTS.md packaging note scrubbed (#744)"
  grep -q "^## Repository Layout" "$TARGET/AGENTS.md" \
    && fail "AGENTS.md still carries the Repository Layout section" \
    || pass "AGENTS.md Repository Layout section removed"
  # Sections on either side must survive the scrub.
  grep -q "^## Code Review Policy" "$TARGET/AGENTS.md" \
    && pass "AGENTS.md scrub left adjacent sections intact" \
    || fail "AGENTS.md scrub over-removed (Code Review Policy section gone)"
else
  fail "AGENTS.md missing from consumer mirror"
fi

# --- assertion 4c2: canonical agent docs land + shared-before-local (#780) ---
# A new repo must come out of bootstrap already carrying the canonical
# shared rulebook, with AGENTS.md pointing at it BEFORE the per-repo
# operating-rules overlay. Both halves are enforced in-stage by
# bootstrap::_verify_canonical_agent_docs; assert the observable result.
canon_missing=""
for d in docs/agents/decision-records.md docs/agents/shared-operating-rules.md docs/agents/worktree-placement.md; do
  [ -f "$TARGET/$d" ] || canon_missing="$canon_missing $d"
done
[ -z "$canon_missing" ] \
  && pass "canonical agent docs seeded into the new repo (#780)" \
  || fail "canonical agent docs missing from the new repo:$canon_missing"
[ -f "$TARGET/docs/agents/operating-rules.md" ] \
  && pass "per-repo operating-rules overlay still seeded alongside the shared core" \
  || fail "docs/agents/operating-rules.md missing from the new repo"

live_overlay_banner=$(sed -n '/^>/,/^$/p' "$ROOT/docs/agents/operating-rules.md")
if printf '%s\n' "$live_overlay_banner" | grep -Eiq "mergepath|#[0-9]+"; then
  fail "live operating-rules banner is not consumer-neutral"
else
  pass "live operating-rules banner is consumer-neutral for bootstrap seeding"
fi
if [ -f "$TARGET/AGENTS.md" ]; then
  shared_ln=$(grep -n -F -m1 'docs/agents/shared-operating-rules.md' "$TARGET/AGENTS.md" | cut -d: -f1 || true)
  local_ln=$(grep -n -F -m1 'docs/agents/operating-rules.md' "$TARGET/AGENTS.md" | cut -d: -f1 || true)
  if [ -n "$shared_ln" ] && [ -n "$local_ln" ] && [ "$shared_ln" -lt "$local_ln" ]; then
    pass "AGENTS.md reads the shared operating rules before the local overlay (#780)"
  else
    fail "AGENTS.md reading order wrong (shared=${shared_ln:-none}, local=${local_ln:-none})"
  fi
fi

# --- assertion 4c3: the in-stage verifier actually fails closed (#780) ---
# The assertions above prove the happy path. Drive
# bootstrap::_verify_canonical_agent_docs directly against deliberately
# broken trees so a future exclude-pattern or index regression cannot
# pass silently — a verifier that never returns non-zero is not a guard.
VERIFY_LIB="$ROOT/scripts/bootstrap/template-mirror.sh"
verify_case() {
  # $1 = scenario label, $2 = target mutation, $3 = optional source-manifest mutation
  local mutate="$2" source_mutate="${3:-:}" vt source rc out
  vt="$(mktemp -d "$WORKDIR/verify.XXXXXX")"
  source="$(mktemp -d "$WORKDIR/verify-source.XXXXXX")"
  cp "$FAKE_MP/.mergepath-sync.yml" "$source/.mergepath-sync.yml"
  mkdir -p "$vt/docs/agents"
  : > "$vt/docs/agents/decision-records.md"
  : > "$vt/docs/agents/shared-operating-rules.md"
  : > "$vt/docs/agents/worktree-placement.md"
  : > "$vt/docs/agents/operating-rules.md"
  printf '## Sections\n\n1. [Shared](docs/agents/shared-operating-rules.md)\n2. [Local](docs/agents/operating-rules.md)\n' > "$vt/AGENTS.md"
  mkdir -p "$source/docs/agents"
  cp "$vt/docs/agents/decision-records.md" "$source/docs/agents/decision-records.md"
  cp "$vt/docs/agents/shared-operating-rules.md" "$source/docs/agents/shared-operating-rules.md"
  cp "$vt/docs/agents/worktree-placement.md" "$source/docs/agents/worktree-placement.md"
  git -C "$source" init -q
  git -C "$source" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
  git -C "$source" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m fixture
  ( cd "$vt" && eval "$mutate" )
  ( cd "$source" && eval "$source_mutate" )
  set +e
  out=$(bash -c '
    bootstrap::log() { :; }
    bootstrap::err() { echo "ERR: $*"; }
    source "$1"
    bootstrap::_verify_canonical_agent_docs "$2" "$3"
  ' _ "$VERIFY_LIB" "$vt" "$source" 2>&1)
  rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}

res=$(verify_case "control" ":")
[ "${res%%|*}" = "0" ] \
  && pass "verifier control: an intact tree passes (#780)" \
  || fail "verifier control unexpectedly failed: ${res#*|}"

res=$(verify_case "derived-required-set" ":" 'yq -i '\''.doc_ownership += [{"path":"docs/agents/new-canonical.md","class":"canonical"}]'\'' .mergepath-sync.yml')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "docs/agents/new-canonical.md"; then
  pass "verifier derives newly backed canonical docs from the source manifest (#780)"
else
  fail "verifier should require a newly backed canonical doc without a copied array update; got: $res"
fi

res=$(verify_case "missing-doc" 'rm docs/agents/shared-operating-rules.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "canonical agent docs missing"; then
  pass "verifier fails closed when a canonical agent doc is absent (#780)"
else
  fail "verifier should fail on a missing canonical doc; got: $res"
fi

res=$(verify_case "stale-canonical" 'printf "stale receiver copy\n" > docs/agents/shared-operating-rules.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "canonical agent docs differ"; then
  pass "verifier rejects a stale receiver-side canonical document (#780)"
else
  fail "verifier should compare canonical document bytes, not merely existence; got: $res"
fi

res=$(verify_case "wrong-canonical-mode" 'chmod +x docs/agents/shared-operating-rules.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "canonical agent docs differ"; then
  pass "verifier rejects a canonical document whose receiver Git mode differs (#780)"
else
  fail "verifier should compare canonical document modes, not merely existence; got: $res"
fi

res=$(verify_case "wrong-order" 'printf "## Sections\n\n1. [Local](docs/agents/operating-rules.md)\n2. [Shared](docs/agents/shared-operating-rules.md)\n" > AGENTS.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "BEFORE docs/agents/shared-operating-rules.md"; then
  pass "verifier fails closed when AGENTS.md lists the local overlay first (#780)"
else
  fail "verifier should fail on a shared-after-local AGENTS.md; got: $res"
fi

res=$(verify_case "same-line-wrong-order" 'printf "## Sections\n\n1. Read [Local](docs/agents/operating-rules.md), then [Shared](docs/agents/shared-operating-rules.md).\n" > AGENTS.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "BEFORE docs/agents/shared-operating-rules.md"; then
  pass "verifier compares columns when both AGENTS.md links share a line (#780)"
else
  fail "verifier should fail when the local link precedes shared on one line; got: $res"
fi

res=$(verify_case "same-line-right-order" 'printf "## Sections\n\n1. Read [Shared](docs/agents/shared-operating-rules.md), then [Local](docs/agents/operating-rules.md).\n" > AGENTS.md')
if [ "${res%%|*}" = "0" ]; then
  pass "verifier accepts shared-before-local links on the same line (#780)"
else
  fail "verifier should accept shared-before-local links on one line; got: $res"
fi

res=$(verify_case "raw-occurrence-before-index" 'printf "<!-- docs/agents/shared-operating-rules.md -->\nProse example: docs/agents/shared-operating-rules.md.\n\n## Sections\n\n1. [Local](docs/agents/operating-rules.md)\n2. [Shared](docs/agents/shared-operating-rules.md)\n" > AGENTS.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "BEFORE docs/agents/shared-operating-rules.md"; then
  pass "verifier ignores raw comment/prose occurrences and checks the visible reading-order links"
else
  fail "raw occurrences must not mask a reversed visible AGENTS.md index; got: $res"
fi

res=$(verify_case "unlinked" 'printf "## Sections\n\n1. [Local](docs/agents/operating-rules.md)\n" > AGENTS.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "does not reference docs/agents/shared-operating-rules.md"; then
  pass "verifier fails closed when AGENTS.md never links the shared rules (#780)"
else
  fail "verifier should fail on an AGENTS.md with no shared-rules link; got: $res"
fi

res=$(verify_case "local-unlinked" 'printf "## Sections\n\n1. [Shared](docs/agents/shared-operating-rules.md)\n" > AGENTS.md')
if [ "${res%%|*}" != "0" ] && printf '%s' "${res#*|}" | grep -q "does not reference docs/agents/operating-rules.md"; then
  pass "verifier fails closed when AGENTS.md never links the local overlay (#780)"
else
  fail "verifier should fail on an AGENTS.md with no local-overlay link; got: $res"
fi

# --- assertion 4d: README.md hub-identity scrub (#747) ---
# The substituted README must have the hub tagline replaced by honest
# downstream framing, the BRAND umbrella-vocabulary framing rewritten,
# and the Key-Files/Directory rows for consumer-excluded surfaces
# dropped — while the genuinely-shared rows and prose flow through.
grep -qF "**A downstream consumer of the [mergepath](https://github.com/nathanjohnpayne/mergepath) AI-agent tooling template.**" "$TARGET/README.md" \
  && pass "README.md tagline replaced with downstream-consumer framing (#747)" \
  || fail "README.md tagline not replaced; got: $(sed -n 3p "$TARGET/README.md")"
grep -qF "Reference implementation of the AI Agent Tooling Standard" "$TARGET/README.md" \
  && fail "README.md still claims reference-implementation status" \
  || pass "README.md reference-implementation claim scrubbed"
grep -qF "for this repo's brand vocabulary (a bootstrap stub until replaced)" "$TARGET/README.md" \
  && pass "README.md BRAND intro sentence rewritten to point at the stub" \
  || fail "README.md BRAND intro sentence not rewritten"
grep -qF "Project brand vocabulary (bootstrap stub" "$TARGET/README.md" \
  && pass "README.md BRAND.md Key-Files row rewritten to the stub description" \
  || fail "README.md BRAND.md Key-Files row not rewritten"
readme_dead=""
for marker in "playground/index.html" "policy-sim.sh" "Propagation manifest" \
              "Mergepath Playground" "Playground and reserved slots" \
              "umbrella vocabulary"; do
  grep -qF "$marker" "$TARGET/README.md" && readme_dead="$readme_dead '$marker'"
done
[ -z "$readme_dead" ] \
  && pass "README.md dead Key-Files/Directory rows for excluded surfaces dropped (#747)" \
  || fail "README.md still carries hub markers:$readme_dead"
# Shared content must survive the scrub.
grep -qF '| `AGENTS.md` | Instructions for AI agents |' "$TARGET/README.md" \
  && grep -qF '| `tests/` | Automated validation |' "$TARGET/README.md" \
  && grep -qF '| `ai_agent_tooling_standard.md` | Full repository standard (reference) |' "$TARGET/README.md" \
  && pass "README.md scrub left the shared Key-Files/Directory rows intact" \
  || fail "README.md scrub over-removed shared rows"

# A consumer is allowed to be named "Playground"; the fail-closed marker
# check must reject hub-only README content, not the consumer's own name.
pg_target="$WORKDIR/playground-target"
mkdir -p "$pg_target"
cat >"$pg_target/README.md" <<'EOF'
# Playground

**Reference implementation of the AI Agent Tooling Standard.**

Playground is this repository's chosen product name. See [`BRAND.md`](BRAND.md) for the umbrella vocabulary (Playground, Cockpit, Tiebreaker, Checks) and naming history.

## Key Files

| File | Purpose |
|---|---|
| `BRAND.md` | Mergepath umbrella vocabulary (surfaces, reserved names, naming history) |
| `mergepath/playground/index.html` | Mergepath Playground — tune the review policy and replay recent PRs against the draft |
| `scripts/policy-sim.sh` | Bakes real `gh` PR data into a temp copy of the Mergepath Playground for local replay |

## Directory Structure

| Directory | Purpose |
|---|---|
| `mergepath/` | Mergepath Playground and reserved slots for future Mergepath surfaces (see `BRAND.md`) |
EOF
set +e
pg_out=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$pg_target"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/substitute.sh"
  . "$ROOT/scripts/bootstrap/template-mirror.sh"
  set +e
  bootstrap_input() { echo "playground"; }
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_LOG_FILE=""
  bootstrap::_scaffold_consumer_identity "$TARGET"
  echo "RC=$?"
' 2>&1)
set -e
echo "$pg_out" | grep -q "RC=0" \
  && pass "README.md scrub allows a consumer-owned Playground name (rc=0)" \
  || fail "README.md scrub rejected a consumer-owned Playground name; out: $pg_out"
grep -qF "# Playground" "$pg_target/README.md" \
  && grep -qF "Playground is this repository's chosen product name." "$pg_target/README.md" \
  && pass "README.md scrub preserves consumer-owned Playground text" \
  || fail "README.md scrub removed consumer-owned Playground text"
pg_dead=""
for marker in "playground/index.html" "policy-sim.sh" "Mergepath Playground" \
              "Playground and reserved slots" "umbrella vocabulary"; do
  grep -qF "$marker" "$pg_target/README.md" && pg_dead="$pg_dead '$marker'"
done
[ -z "$pg_dead" ] \
  && pass "README.md scrub still removes hub-only Playground markers" \
  || fail "README.md scrub left hub-only Playground markers:$pg_dead"

# --- assertion 4e: REVIEW_POLICY.md wave-audit reframe (#747) ---
# The verbatim-copied policy must have the hub-only wave-audit
# paragraph replaced with a hub-side pointer, plus a consumer note
# right after the Phase 3.5 heading framing the hub-script references.
if [ -f "$TARGET/REVIEW_POLICY.md" ]; then
  grep -qF "**Wave audit (#662).**" "$TARGET/REVIEW_POLICY.md" \
    && fail "REVIEW_POLICY.md still carries the hub-only wave-audit paragraph" \
    || pass "REVIEW_POLICY.md hub-only wave-audit paragraph replaced (#747)"
  grep -qF "**Wave audit (hub-side).**" "$TARGET/REVIEW_POLICY.md" \
    && pass "REVIEW_POLICY.md carries the hub-side wave-audit pointer" \
    || fail "REVIEW_POLICY.md missing the hub-side wave-audit pointer"
  grep -qF "Full procedure: \`docs/agents/propagation-ordering.md\`" "$TARGET/REVIEW_POLICY.md" \
    && fail "REVIEW_POLICY.md still hard-links the excluded propagation-ordering.md as a local doc" \
    || pass "REVIEW_POLICY.md no longer hard-links propagation-ordering.md locally"
  grep -A2 "^### Phase 3.5: Propagation PR review lane" "$TARGET/REVIEW_POLICY.md" \
      | grep -qF "Consumer note (hub-side machinery)" \
    && pass "REVIEW_POLICY.md consumer note inserted after the Phase 3.5 heading" \
    || fail "REVIEW_POLICY.md consumer note missing or misplaced"
  # audit-propagation-lane.sh IS synced to every consumer (manifest
  # consumers: all) — the note must frame it as a local synced copy
  # whose live mode runs from the hub, never as absent from this repo.
  grep -qF '(`scripts/audit-propagation-lane.sh` is different: this repo carries a synced copy' "$TARGET/REVIEW_POLICY.md" \
    && pass "REVIEW_POLICY.md note distinguishes the synced audit-propagation-lane.sh copy" \
    || fail "REVIEW_POLICY.md note misframes audit-propagation-lane.sh (it IS synced to consumers)"
  # A fresh bootstrap is NOT yet an enrolled sync consumer — both the
  # note and the wave pointer must qualify fan-out receipt.
  grep -qF "once enrolled as a sync consumer" "$TARGET/REVIEW_POLICY.md" \
    && grep -qF "once this repository is enrolled as a sync consumer" "$TARGET/REVIEW_POLICY.md" \
    && pass "REVIEW_POLICY.md qualifies fan-out receipt with 'once enrolled' (#747 r1)" \
    || fail "REVIEW_POLICY.md claims unconditional fan-out receipt (enrollment is a later step)"
  # Adjacent sections and the in-section cross-ref must survive.
  grep -q "^### Phase 4: External Review" "$TARGET/REVIEW_POLICY.md" \
    && grep -qF "see Wave audit below" "$TARGET/REVIEW_POLICY.md" \
    && pass "REVIEW_POLICY.md reframe left adjacent sections + cross-ref intact" \
    || fail "REVIEW_POLICY.md reframe over-removed (Phase 4 heading or cross-ref gone)"
else
  fail "REVIEW_POLICY.md missing from consumer mirror"
fi

# --- assertion 4f: wave-audit reframe consumes a HARD-WRAPPED paragraph ---
# The repo enforces soft-wrap, so the real wave-audit paragraph is one
# physical line — but the replacement must not silently leak
# continuation lines if the paragraph ever arrives hard-wrapped (the
# fail-closed marker check only sees the marker's own line). Invoke the
# scaffold helper directly against a fixture whose paragraph spans
# three lines and assert every line of it is consumed.
hw_target="$WORKDIR/hardwrap-target"
mkdir -p "$hw_target"
cat >"$hw_target/REVIEW_POLICY.md" <<'EOF'
# Policy

### Phase 3.5: Propagation PR review lane

Lane intro survives.

**Wave audit (#662).** `scripts/wave-audit.sh` dispatches a scoped
automated Phase 4b review against the wave canary, over the range
since the last `wave-audit-pass/<sha>` watermark tag.
Full procedure: `docs/agents/propagation-ordering.md` § Wave audit.

### Phase 4: External Review

Phase 4 body survives.
EOF
set +e
hw_out=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$hw_target"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/substitute.sh"
  . "$ROOT/scripts/bootstrap/template-mirror.sh"
  set +e
  bootstrap_input() { echo "my-new-repo"; }
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_LOG_FILE=""
  bootstrap::_scaffold_consumer_identity "$TARGET"
  echo "RC=$?"
' 2>&1)
set -e
echo "$hw_out" | grep -q "RC=0" \
  && pass "scaffold helper handles the hard-wrapped fixture (rc=0)" \
  || fail "scaffold helper failed on hard-wrapped fixture; out: $hw_out"
hw_leak=""
for remnant in "dispatches a scoped" "watermark tag" \
               "Full procedure: \`docs/agents/propagation-ordering.md\`"; do
  grep -qF "$remnant" "$hw_target/REVIEW_POLICY.md" && hw_leak="$hw_leak '$remnant'"
done
[ -z "$hw_leak" ] \
  && pass "hard-wrapped wave-audit paragraph fully consumed (no continuation-line leak)" \
  || fail "hard-wrapped wave-audit continuation lines survived:$hw_leak"
grep -qF "**Wave audit (hub-side).**" "$hw_target/REVIEW_POLICY.md" \
  && pass "hard-wrapped fixture got the hub-side wave-audit pointer" \
  || fail "hub-side wave-audit pointer missing from hard-wrapped fixture"
grep -qF "Lane intro survives." "$hw_target/REVIEW_POLICY.md" \
  && grep -qF "Phase 4 body survives." "$hw_target/REVIEW_POLICY.md" \
  && pass "hard-wrapped consume stopped at the paragraph boundary (neighbors intact)" \
  || fail "hard-wrapped consume over-ran the paragraph boundary"

# --- assertion 4g: wave-audit reframe stops at a heading with NO blank
#     line before it (Codex round-2 #3662388686) ---
# Valid Markdown does not require a blank line between a paragraph and
# the heading that follows it. The paragraph consumer must stop at the
# heading rather than swallowing it as a "continuation line" of the
# hard-wrap case above.
nb_target="$WORKDIR/noblank-target"
mkdir -p "$nb_target"
cat >"$nb_target/REVIEW_POLICY.md" <<'EOF'
# Policy

### Phase 3.5: Propagation PR review lane

Lane intro survives.

**Wave audit (#662).** `scripts/wave-audit.sh` dispatches a scoped automated Phase 4b review against the wave canary.
### Phase 4: External Review

Phase 4 body survives.
EOF
set +e
nb_out=$(bash -c '
  ROOT="'"$ROOT"'"
  TARGET="'"$nb_target"'"
  . "$ROOT/scripts/bootstrap/_lib.sh"
  . "$ROOT/scripts/bootstrap/substitute.sh"
  . "$ROOT/scripts/bootstrap/template-mirror.sh"
  set +e
  bootstrap_input() { echo "my-new-repo"; }
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_LOG_FILE=""
  bootstrap::_scaffold_consumer_identity "$TARGET"
  echo "RC=$?"
' 2>&1)
set -e
echo "$nb_out" | grep -q "RC=0" \
  && pass "scaffold helper handles the no-blank-line-before-heading fixture (rc=0)" \
  || fail "scaffold helper failed on no-blank-line-before-heading fixture; out: $nb_out"
grep -q "^### Phase 4: External Review" "$nb_target/REVIEW_POLICY.md" \
  && pass "Phase 4 heading survives when it directly follows the wave-audit paragraph (no blank line)" \
  || fail "Phase 4 heading was swallowed by the wave-audit paragraph consumer"
grep -qF "Phase 4 body survives." "$nb_target/REVIEW_POLICY.md" \
  && pass "Phase 4 body survives the no-blank-line-before-heading reframe" \
  || fail "Phase 4 body lost in the no-blank-line-before-heading reframe"
grep -qF "**Wave audit (hub-side).**" "$nb_target/REVIEW_POLICY.md" \
  && pass "no-blank-line-before-heading fixture got the hub-side wave-audit pointer" \
  || fail "hub-side wave-audit pointer missing from no-blank-line-before-heading fixture"
grep -qF "Lane intro survives." "$nb_target/REVIEW_POLICY.md" \
  && pass "no-blank-line-before-heading consume stopped at the paragraph boundary (neighbors intact)" \
  || fail "no-blank-line-before-heading consume over-ran the paragraph boundary"

# .ai_context.md has no mergepath refs to begin with — substitution
# should produce a byte-identical file (warning logged but no error).
diff -q "$FAKE_MP/.ai_context.md" "$TARGET/.ai_context.md" >/dev/null \
  && pass ".ai_context.md (no mergepath refs) substituted as no-op" \
  || fail ".ai_context.md content drifted unexpectedly"

# --- assertion 5: .repo-template.yml cleanup ---
if yq '.spec_test_map.mergepath_playground' "$TARGET/.repo-template.yml" 2>/dev/null \
     | grep -q "tests/test_mergepath_playground"; then
  fail "playground spec_test_map entry not removed"
else
  pass "playground spec_test_map entry removed"
fi
# extra_top_level_dirs must be gone.
if yq 'has("extra_top_level_dirs")' "$TARGET/.repo-template.yml" 2>/dev/null \
     | grep -q true; then
  fail "extra_top_level_dirs not removed"
else
  pass "extra_top_level_dirs key removed"
fi
# The bootstrap consumer-identity entry must be gone too (#747: its
# spec and mapped hub-only test are both mirror-excluded, so a
# surviving map entry is stale hub metadata in the consumer).
if yq '.spec_test_map.bootstrap_consumer_identity' "$TARGET/.repo-template.yml" 2>/dev/null \
     | grep -q "tests/test_bootstrap_template_mirror"; then
  fail "bootstrap_consumer_identity spec_test_map entry not removed"
else
  pass "bootstrap_consumer_identity spec_test_map entry removed"
fi
# Same for the source-SHA-attribution spec (#1056, Codex P2 round 4 on
# #1112): its spec file is mirror-excluded too, so a surviving map entry
# would be equally stale.
if yq '.spec_test_map.bootstrap_source_attribution' "$TARGET/.repo-template.yml" 2>/dev/null \
     | grep -q "tests/test_bootstrap_template_mirror"; then
  fail "bootstrap_source_attribution spec_test_map entry not removed"
else
  pass "bootstrap_source_attribution spec_test_map entry removed"
fi
[ -f "$TARGET/specs/bootstrap_source_attribution.md" ] \
  && fail "specs/bootstrap_source_attribution.md leaked into the consumer (its links to hub-only docs would 404)" \
  || pass "specs/bootstrap_source_attribution.md excluded from the consumer mirror"
# But some_other_spec entry should remain (we only dropped the hub-only ones).
yq '.spec_test_map.some_other_spec' "$TARGET/.repo-template.yml" 2>/dev/null \
  | grep -q "tests/test_some_other" \
  && pass "unrelated spec_test_map entries preserved" \
  || fail "unrelated spec_test_map entry was accidentally dropped"

# --- assertion 6: target has a single initial commit ---
[ -d "$TARGET/.git" ] \
  && pass "target has .git initialized" \
  || fail "target missing .git after stage B"
commit_count=$(git -C "$TARGET" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$commit_count" = "1" ] \
  && pass "target has exactly 1 initial commit" \
  || fail "expected 1 commit, got $commit_count"
git -C "$TARGET" log -1 --format=%s | grep -q "Initial commit (bootstrapped from mergepath@${FAKE_MP_SHA:0:7})" \
  && pass "initial commit subject names the mergepath source sha (#1056)" \
  || fail "initial commit subject wrong: $(git -C "$TARGET" log -1 --format=%s)"
git -C "$TARGET" log -1 --format=%b | grep -qF "Source: https://github.com/nathanjohnpayne/mergepath/commit/${FAKE_MP_SHA}" \
  && pass "initial commit carries a Source: trailer naming the full mergepath sha (#1056)" \
  || fail "initial commit missing Source: trailer: $(git -C "$TARGET" log -1 --format=%b)"

# --- assertion 7: cross-repo loop step skipped (no anchors) ---
# The fixture has no DEPLOYMENT.md, and its REVIEW_POLICY.md carries no
# '<!-- bootstrap-loop-list-end -->' anchor, so the step should warn
# and bail without modifying the source.
# After running, mergepath fixture's worktree should still be clean
# on main with only the initial fixture commit.
fixture_commits=$(git -C "$FAKE_MP" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$fixture_commits" = "1" ] \
  && pass "cross-repo loop step did not touch mergepath fixture" \
  || fail "expected fixture to remain at 1 commit; got $fixture_commits"
fixture_dirty=$(git -C "$FAKE_MP" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[ "$fixture_dirty" = "0" ] \
  && pass "mergepath fixture worktree is clean after stage B" \
  || fail "mergepath fixture is dirty: $(git -C "$FAKE_MP" status --porcelain)"
# No new branch should be left behind.
fixture_branches=$(git -C "$FAKE_MP" branch --format='%(refname:short)' | sort)
echo "$fixture_branches" | grep -q "^bootstrap/" \
  && fail "stray bootstrap/* branch left on fixture: $fixture_branches" \
  || pass "no stray bootstrap/* branch on fixture"

# --- assertion 8: state file recorded template-mirror ---
[ -f "$TARGET/.bootstrap-state" ] \
  && grep -q "^template-mirror$" "$TARGET/.bootstrap-state" \
  && pass "state file records template-mirror completion" \
  || fail "state file missing template-mirror entry"

# --- assertion 8b: phase_4b_automation.enabled reset to false in target (#628) ---
mirrored_policy="$TARGET/.github/review-policy.yml"
if [ -f "$mirrored_policy" ] \
   && awk '/^phase_4b_automation:/{b=1;next} b&&/^[^ #]/{b=0} b&&/^  enabled:/{print $2; exit}' "$mirrored_policy" | grep -qx "false" \
   && awk '/^  accounting:/{a=1;next} a&&/^    enabled:/{print $2; exit}' "$mirrored_policy" | grep -qx "true" \
   && awk '/^coderabbit:/{c=1;next} c&&/^[^ #]/{c=0} c&&/^  enabled:/{print $2; exit}' "$mirrored_policy" | grep -qx "true"; then
  pass "mirrored review-policy resets phase_4b_automation.enabled to false; accounting + coderabbit enables untouched (#628)"
else
  fail "phase-4b default reset wrong: $(grep -n 'enabled:' "$mirrored_policy" 2>/dev/null | head -5)"
fi

# --- assertion 9: --dry-run path produces no on-disk side effects ---
dry_target="$WORKDIR/dry-target"
set +e
dry_out=$(BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
          BOOTSTRAP_SKIP_TOOL_CHECK=1 \
          BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
          BOOTSTRAP_AUTO_CONFIRM=1 \
          BOOTSTRAP_AUTO_PROMPT=skip \
          BOOTSTRAP_SKIP_STAGES="github-infra,firebase-and-codereview,board-and-summary" \
          "$SCRIPT" my-new-repo \
            --target-dir "$dry_target" \
            --description "d" --visibility private \
            --firebase none --codex-app n --project new --dry-run 2>&1)
dry_ec=$?
set -e
[ "$dry_ec" -eq 0 ] \
  && pass "stage B --dry-run exits 0" \
  || fail "dry-run failed: rc=$dry_ec; out: $dry_out"
# Dry-run target should not have a populated tree — only the state
# file (which the bootstrap wrapper writes regardless of dry-run).
[ ! -e "$dry_target/README.md" ] \
  && pass "dry-run did not actually rsync into target" \
  || fail "dry-run materialized README.md unexpectedly"
echo "$dry_out" | grep -q "DRY-RUN" \
  && pass "dry-run output includes [DRY-RUN] tags" \
  || fail "dry-run output missing [DRY-RUN]: $dry_out"

# --- assertion 10: substitute.sh idempotent ---
# Re-substituting an already-substituted file should be a no-op.
# SECURITY.md is the probe since #747: the scrubbed README.md now
# intentionally carries a literal hub reference ("[mergepath](...)"
# in the scaffold-written tagline), so it is no longer a substitution
# fixed point — and never re-enters substitution in the real flow,
# because the scaffold step runs after it.
cp "$TARGET/SECURITY.md" "$WORKDIR/security-once.md"
# Source the substitute lib + invoke directly.
. "$ROOT/scripts/bootstrap/_lib.sh"
. "$ROOT/scripts/bootstrap/substitute.sh"
BOOTSTRAP_DRY_RUN=0 BOOTSTRAP_LOG_FILE="" \
  bootstrap::_substitute_one_file \
    "$WORKDIR/security-once.md" \
    "my-new-repo" \
    "https://github.com/nathanjohnpayne/my-new-repo" \
    "a test repo" >/dev/null 2>&1
diff -q "$TARGET/SECURITY.md" "$WORKDIR/security-once.md" >/dev/null \
  && pass "substitute_one_file is idempotent on already-substituted content" \
  || fail "substitute_one_file is not idempotent"

# --- assertion 11: step ordering — .repo-template.yml cleanup BEFORE
# substitution (CodeRabbit + Codex round 1 on #233). If substitution
# ran first, the `mergepath_playground` key would already have been
# renamed to e.g. `my-new-repo_playground` and yq's
# `del(.spec_test_map.mergepath_playground)` would silently miss.
# Pin the ordering via a source-grep so a future refactor that swaps
# the two calls back fails this test.
# ---------------------------------------------------------------------------
awk '
  /^bootstrap::stage_template_mirror\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /bootstrap::_clean_repo_template_yml/  { saw_clean = NR }
  in_fn && /bootstrap::apply_name_substitutions/  { saw_sub   = NR }
  END {
    if (!saw_clean) { print "missing _clean_repo_template_yml call in stage"; exit 1 }
    if (!saw_sub)   { print "missing apply_name_substitutions call in stage"; exit 1 }
    if (saw_clean > saw_sub) {
      print "ordering wrong: _clean_repo_template_yml must run BEFORE apply_name_substitutions"
      exit 1
    }
  }
' "$ROOT/scripts/bootstrap/template-mirror.sh" \
  && pass "stage runs .repo-template.yml cleanup BEFORE substitution" \
  || fail "stage ordering invariant violated — cleanup must precede substitution"

# --- assertion 12: stage propagates sub-step failures (Codex #233 P1).
# The dispatch in scripts/bootstrap-new-repo.sh invokes stages as
# `"$fn" || stage_rc=$?`, which disables `set -e` inside the stage
# under bash. Without explicit per-step rc capture + early return,
# a failing sub-step would still record the stage as completed and
# `--resume` would skip past it. Cover by simulating a failure in
# the substitution lib: invoke the stage with a non-writable target
# .repo-template.yml that yq can't edit (chmod 0444). The cleanup
# step should propagate the failure; the stage must return non-zero
# and the state file must NOT carry a "template-mirror" entry.
# ---------------------------------------------------------------------------
fail_target="$WORKDIR/fail-target"
rm -rf "$fail_target"
mkdir -p "$fail_target"
# Pre-create a .repo-template.yml at the target with read-only parent
# so the post-rsync yq -i edit fails. Easiest: lock the file itself.
# rsync writes to target after the mode mirror, so we need to lock
# the file AFTER rsync but BEFORE cleanup. Cheaper: lock the whole
# target dir so cleanup's `yq -i` can't open the file for write.
# But that breaks rsync too. So: simulate via a stub stage that calls
# the stage function directly with a pre-populated locked file.
#
# Simpler: shim the underlying yq via PATH override to always exit 1.
shim_dir="$WORKDIR/shim-bin"
mkdir -p "$shim_dir"
cat >"$shim_dir/yq" <<'SHIM_EOF'
#!/usr/bin/env bash
# Test shim — always exits 1 to simulate yq failure on the cleanup step.
echo "yq shim: deliberate failure for test_bootstrap_template_mirror" >&2
exit 1
SHIM_EOF
chmod +x "$shim_dir/yq"

set +e
fail_out=$(PATH="$shim_dir:$PATH" \
           BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
           BOOTSTRAP_SKIP_TOOL_CHECK=1 \
           BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
           BOOTSTRAP_AUTO_CONFIRM=1 \
           BOOTSTRAP_AUTO_PROMPT=skip \
           BOOTSTRAP_AUTHOR_NAME="test" \
           BOOTSTRAP_AUTHOR_EMAIL="t@t" \
      BOOTSTRAP_SKIP_STAGES="github-infra,firebase-and-codereview,board-and-summary" \
           "$SCRIPT" my-new-repo \
             --target-dir "$fail_target" \
             --description "test repo" --visibility private \
             --firebase none --codex-app n --project new 2>&1)
fail_ec=$?
set -e
# yq is also used in the wizard's preflight if .repo-template.yml
# parsing is exercised, but the wizard's own require_yq is skipped
# under BOOTSTRAP_SKIP_TOOL_CHECK. So the only place the shim's yq
# fires is bootstrap::_yq_clean_repo_template inside the stage —
# exactly the regression we're guarding.
[ "$fail_ec" -ne 0 ] \
  && pass "stage propagates yq failure on .repo-template.yml cleanup (rc=$fail_ec)" \
  || fail "stage should have returned non-zero when yq fails; got rc=$fail_ec, out: $fail_out"

# State file must NOT have a "template-mirror" entry — the failed
# stage should not be marked as completed.
if [ -f "$fail_target/.bootstrap-state" ] && grep -q "^template-mirror$" "$fail_target/.bootstrap-state"; then
  fail "failed stage was recorded as completed in state file"
else
  pass "failed stage NOT recorded in state file (resume can retry)"
fi

# --- assertion 13: stage fails closed when yq is unavailable
# (Codex round 3 P1 on #233). Before the fix the stage logged a
# warning and returned 0 + recorded completion — shipping a target
# repo whose .repo-template.yml still carried `mergepath_playground`
# (later renamed to `<new-repo>_playground` by substitution).
#
# Simulate by invoking the cleanup helper directly with yq absent
# from PATH. Use the stage's helper via source rather than going
# through the whole wizard, so the test is fast + isolated.
# ---------------------------------------------------------------------------
#
# CI guard: the hermetic PATH this assertion builds intentionally
# omits yq, then chains `/usr/bin:/bin` to resolve coreutils. On a
# GitHub Actions ubuntu-latest runner, `yq` is preinstalled at
# `/usr/bin/yq` (see repo_lint.yml's install_yq_for_sync_manifest
# comment: "The official ubuntu-latest runner ships yq 4.x
# preinstalled today"), which leaks yq back into the "no-yq" path
# and defeats the assertion: `_clean_repo_template_yml` resolves
# yq, returns 0, and modifies the file. Detect that case and SKIP;
# dev machines (where yq is brew-installed under /opt/homebrew/bin,
# NOT /usr/bin) still exercise this case. (nathanpayne-codex Phase
# 4b r2 on PR #289.)
if [ -x "/usr/bin/yq" ]; then
  echo "SKIP: /usr/bin/yq present (preinstalled on CI runner) — Test 13 (stage fails closed when yq missing) cannot construct a hermetic PATH that excludes yq while still resolving coreutils via /usr/bin"
else
  # Set up a target with a real .repo-template.yml so the missing-file
  # fast-path doesn't fire.
  no_yq_target="$WORKDIR/no-yq-target"
  mkdir -p "$no_yq_target"
  cat >"$no_yq_target/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
extra_top_level_dirs: [mergepath, packaging]
EOF
  # Manufactured PATH with no yq.
  no_yq_path="$WORKDIR/no-yq-path"
  mkdir -p "$no_yq_path"
  for tool in bash sed awk mktemp; do
    src=$(command -v "$tool" || true)
    if [ -n "$src" ]; then ln -sf "$src" "$no_yq_path/$tool"; fi
  done
  set +e
  # Source the libs + invoke the helper directly under the stripped PATH.
  no_yq_out=$(PATH="$no_yq_path:/usr/bin:/bin" bash -c '
    ROOT="'"$ROOT"'"
    TARGET="'"$no_yq_target"'"
    . "$ROOT/scripts/bootstrap/_lib.sh"
    . "$ROOT/scripts/bootstrap/substitute.sh"
    . "$ROOT/scripts/bootstrap/template-mirror.sh"
    # The libs set `set -euo pipefail`; defeat -e here so we can
    # capture the helper rc into a variable and echo it. -u + pipefail
    # are still desirable safety nets but -e would exit the subshell
    # before reaching the echo on a non-zero rc.
    set +e
    BOOTSTRAP_DRY_RUN=0
    BOOTSTRAP_LOG_FILE=""
    bootstrap::_clean_repo_template_yml "$TARGET"
    echo "RC=$?"
  ' 2>&1)
  set -e
  # The helper should return non-zero (rc=2 per the impl) AND emit a
  # diagnostic mentioning yq.
  echo "$no_yq_out" | grep -q "yq is required" \
    && pass "_clean_repo_template_yml errors with 'yq is required' diagnostic when yq missing" \
    || fail "expected 'yq is required' diagnostic; got: $no_yq_out"
  echo "$no_yq_out" | grep -q "RC=2" \
    && pass "_clean_repo_template_yml returns rc=2 when yq missing (fails closed)" \
    || fail "expected RC=2 in subshell; got: $no_yq_out"
  # Verify the .repo-template.yml content is UNCHANGED (the helper
  # returned before yq -i could run; nothing got modified).
  grep -q "mergepath_playground" "$no_yq_target/.repo-template.yml" \
    && pass ".repo-template.yml left untouched when yq missing (no half-write)" \
    || fail ".repo-template.yml was modified despite missing yq"
fi

# --- assertion 14: wizard preflight rejects missing yq (Codex round 3
# P1 — the fail-closed defense is paired with a hard preflight gate
# so the operator gets a clear message at the top instead of mid-stage).
# Manufacture a PATH with all required tools EXCEPT yq, and verify
# the wizard exits non-zero with a clear yq error.
# ---------------------------------------------------------------------------
#
# CI guard: this assertion needs two preconditions to faithfully
# exercise the preflight's "missing yq" branch:
#
#   (a) `op` (1Password CLI) must be on the host — the symlink loop
#       below iterates {bash, gh, op, git, rsync}; on a GH Actions
#       runner `command -v op` returns empty, the symlink is skipped,
#       and the preflight then complains about missing `op` first
#       (the loop order in scripts/bootstrap-new-repo.sh is
#       `gh op git yq rsync` — `op` fires before `yq`).
#   (b) `/usr/bin/yq` must NOT exist — otherwise yq leaks into the
#       hermetic PATH via the `/usr/bin:/bin` chain and the preflight
#       has nothing to complain about (same root cause as Test 13).
#
# Both fail on ubuntu-latest GH runners. SKIP when either is true;
# dev machines (where op is on PATH and yq is at /opt/homebrew/bin/yq
# rather than /usr/bin/yq) still exercise the full case.
if ! command -v op >/dev/null 2>&1; then
  echo "SKIP: 'op' (1Password CLI) not on host PATH — Test 14 (preflight rejects missing yq) cannot construct a hermetic PATH that includes op on CI runners"
elif [ -x "/usr/bin/yq" ]; then
  echo "SKIP: /usr/bin/yq present (preinstalled on CI runner) — Test 14 cannot construct a hermetic PATH that excludes yq while still resolving coreutils via /usr/bin"
else
  preflight_target="$WORKDIR/preflight-noyq-target"
  mkdir -p "$preflight_target"
  preflight_path="$WORKDIR/preflight-noyq-path"
  mkdir -p "$preflight_path"
  for tool in bash gh op git rsync; do
    src=$(command -v "$tool" || true)
    if [ -n "$src" ]; then ln -sf "$src" "$preflight_path/$tool"; fi
  done
  set +e
  pf_out=$(PATH="$preflight_path:/usr/bin:/bin" \
           BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
           BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
           BOOTSTRAP_AUTO_CONFIRM=1 \
           BOOTSTRAP_AUTO_PROMPT=skip \
           "$SCRIPT" my-new-repo \
             --target-dir "$preflight_target" \
             --description d --visibility private \
             --firebase none --codex-app n --project new --dry-run 2>&1)
  pf_ec=$?
  set -e
  [ "$pf_ec" -ne 0 ] \
    && pass "wizard preflight rejects missing yq (rc=$pf_ec)" \
    || fail "wizard should reject missing yq; got rc=$pf_ec, out: $pf_out"
  echo "$pf_out" | grep -q "missing required dependency: yq" \
    && pass "wizard preflight emits 'missing required dependency: yq' diagnostic" \
    || fail "expected 'missing required dependency: yq'; got: $pf_out"
fi

# --- assertion 15: _cross_repo_loop_update propagates failures from
# every side-effect step. Codex round 4 P1 caught that bootstrap::run
# calls inside this helper weren't capturing rc; a mid-flight failure
# (push, gh pr create, etc.) could be masked by the success of the
# subsequent return-to-main checkout, leading the outer stage to
# record completion despite NOT actually opening the loop PR.
# ---------------------------------------------------------------------------
# Source-grep assertion: each bootstrap::run / direct side-effect call
# inside _cross_repo_loop_update must be followed by `|| step_rc=$?`
# OR a `|| pr_create_rc=$?` (the pr-create path uses a different
# variable because it must survive the auth-restore step).
awk '
  /^bootstrap::_cross_repo_loop_update\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  # Count bootstrap::run calls and how many capture rc.
  in_fn && /bootstrap::run / { runs++ }
  in_fn && /\|\| (step_rc|pr_create_rc)=\$\?/ { captures++ }
  END {
    if (runs == 0) { print "no bootstrap::run calls in _cross_repo_loop_update"; exit 1 }
    if (captures < runs) {
      printf "fewer rc captures (%d) than bootstrap::run calls (%d) in _cross_repo_loop_update\n", captures, runs
      exit 1
    }
  }
' "$ROOT/scripts/bootstrap/template-mirror.sh" \
  && pass "_cross_repo_loop_update captures rc from every bootstrap::run call (#233 round 4 P1)" \
  || fail "rc-capture discipline violated in _cross_repo_loop_update"

# --- assertion 16: _cross_repo_loop_update opens the PR through the
# author-token helper and never calls gh auth switch. Codex round 4 P1
# caught the missing author attribution; #412 moved the enforcement
# from keyring switch-around to scripts/gh-as-author.sh.
# ---------------------------------------------------------------------------
awk '
  /^bootstrap::_cross_repo_loop_update\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /BOOTSTRAP_AUTHOR_IDENTITY|nathanjohnpayne/ { saw_author = 1 }
  in_fn && /bootstrap::run_author_gh / { saw_helper = NR }
  in_fn && /^[[:space:]]*pr create / { saw_pr = NR }
  in_fn && /gh auth switch/ { saw_switch = NR }
  END {
    if (!saw_author)  { print "missing author-identity reference in _cross_repo_loop_update"; exit 1 }
    if (!saw_helper)  { print "missing bootstrap::run_author_gh in _cross_repo_loop_update"; exit 1 }
    if (!saw_pr)      { print "missing pr create arguments under bootstrap::run_author_gh"; exit 1 }
    if (saw_helper > saw_pr) { print "bootstrap::run_author_gh must precede pr create arguments"; exit 1 }
    if (saw_switch)   { print "gh auth switch must not appear in _cross_repo_loop_update"; exit 1 }
  }
' "$ROOT/scripts/bootstrap/template-mirror.sh" \
  && pass "_cross_repo_loop_update routes gh pr create through author-token helper" \
  || fail "author-token helper invariant violated"

# --- assertion 17: _anchor_insert must not leak a RETURN trap (#733) ---
# Pre-fix, bootstrap::_anchor_insert installed `trap 'rm -f "$tmp"' RETURN`.
# Bash does not scope a RETURN trap to the function that set it, so the
# trap stayed installed and re-fired when the CALLER (bootstrap::run)
# returned — in a frame where $tmp is unbound — and under `set -u` the
# whole wizard died with "tmp: unbound variable". Drive a LIVE
# (non-dry-run) insert through bootstrap::run under `set -euo pipefail`
# and assert: the shell survives past bootstrap::run's return, the line
# lands above the anchor, and no orphan bootstrap-loop.* tmpfiles remain.
# ---------------------------------------------------------------------------
ANCHOR_TMPDIR="$WORKDIR/anchor-tmp"
mkdir -p "$ANCHOR_TMPDIR"
ANCHOR_DOC="$WORKDIR/anchor-doc.md"
printf 'header\n<!-- bootstrap-loop-list-end -->\nfooter\n' >"$ANCHOR_DOC"
set +e
trap_out=$(
  TMPDIR="$ANCHOR_TMPDIR" BOOTSTRAP_DRY_RUN=0 BOOTSTRAP_LOG_FILE="" bash -c '
    set -euo pipefail
    # shellcheck disable=SC1091
    . "$1/scripts/bootstrap/_lib.sh"
    # shellcheck disable=SC1091
    . "$1/scripts/bootstrap/template-mirror.sh"
    bootstrap::run "insert test-repo above anchor (set -u regression #733)" \
      bootstrap::_anchor_insert "$2" "<!-- bootstrap-loop-list-end -->" "- test-repo"
    echo "SURVIVED-RETURN"
  ' _ "$ROOT" "$ANCHOR_DOC" 2>&1
)
trap_ec=$?
set -e
if [ "$trap_ec" -eq 0 ] && echo "$trap_out" | grep -q "SURVIVED-RETURN"; then
  pass "live _anchor_insert + bootstrap::run return survives under set -u (#733)"
else
  fail "leaked RETURN trap regression: rc=$trap_ec, out: $trap_out"
fi
awk '
  /- test-repo/ { line_at = NR }
  /<!-- bootstrap-loop-list-end -->/ { anchor_at = NR }
  END { exit !(line_at && anchor_at && line_at < anchor_at) }
' "$ANCHOR_DOC" \
  && pass "_anchor_insert placed the line above the anchor" \
  || fail "anchor insert content wrong: $(cat "$ANCHOR_DOC")"
orphans=$(find "$ANCHOR_TMPDIR" -name 'bootstrap-loop.*' | wc -l | tr -d ' ')
[ "$orphans" -eq 0 ] \
  && pass "no orphan bootstrap-loop.* tmpfiles after successful insert" \
  || fail "$orphans orphan tmpfile(s) left in $ANCHOR_TMPDIR"

# --- assertion 18: _anchor_insert failure path still cleans its tmpfile ---
# The RETURN trap existed to guarantee orphan-tmpfile cleanup (CodeRabbit
# on #233 round 2). The #733 fix replaces it with inline `rm -f` on each
# exit path — verify the guarantee held by forcing the awk read to fail
# (missing doc) and asserting no tmpfile is left behind.
# ---------------------------------------------------------------------------
set +e
TMPDIR="$ANCHOR_TMPDIR" bash -c '
  set -uo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_anchor_insert "$2/does-not-exist.md" "anchor" "- x"
' _ "$ROOT" "$WORKDIR" >/dev/null 2>&1
fail_ec=$?
set -e
[ "$fail_ec" -ne 0 ] \
  && pass "_anchor_insert returns non-zero when the doc is unreadable" \
  || fail "_anchor_insert should fail on a missing doc"
orphans=$(find "$ANCHOR_TMPDIR" -name 'bootstrap-loop.*' | wc -l | tr -d ' ')
[ "$orphans" -eq 0 ] \
  && pass "failure path cleaned up its tmpfile (no orphans, #233 guarantee kept)" \
  || fail "$orphans orphan tmpfile(s) left after failure path"

# --- resumed-mirror stale-glossary removal (#864) -------------------------
# --exclude only skips the transfer; a receiver populated by an earlier or
# interrupted Stage B keeps its stale hub-glossary copy unless the
# post-mirror removal also names CONTEXT.md. Assert the helper directly,
# since wizard preflight (correctly) refuses populated targets.
RESUME_DIR="$WORKDIR/resumed-target"
mkdir -p "$RESUME_DIR/tests"
printf 'stale hub glossary\n' >"$RESUME_DIR/CONTEXT.md"
printf 'stale orphan\n' >"$RESUME_DIR/tests/test_mergepath_playground.sh"

# The helper runs in a subshell so lib state cannot leak, but source and
# helper failures REACH the harness: the subshell rc is captured and
# asserted, never discarded. Only the bootstrap::run fallback (plain
# execution when the lib lacks it) is tolerated.
run_remove_orphans() { # run_remove_orphans <dir> — echoes the subshell rc
  local rc=0
  (
    set -e
    source "$MIRROR_LIB"
    if ! declare -F bootstrap::run >/dev/null 2>&1; then
      bootstrap::run() { shift; "$@"; }
    fi
    if ! declare -F bootstrap::err >/dev/null 2>&1; then
      bootstrap::err() { echo "ERR: $*" >&2; }
    fi
    bootstrap::_remove_orphans "$1"
  ) >&2 || rc=$?
  # The lib logs to stdout; route it to stderr above so the echoed rc is the
  # ONLY stdout of this helper and command substitution stays clean.
  echo "$rc"
}

rc="$(run_remove_orphans "$RESUME_DIR")"
[ "$rc" -eq 0 ] \
  && pass "resumed-mirror cleanup exits 0 on success" \
  || fail "resumed-mirror cleanup returned rc=$rc on the happy path"
[ ! -e "$RESUME_DIR/CONTEXT.md" ] \
  && pass "resumed mirror removes stale CONTEXT.md (#864)" \
  || fail "stale CONTEXT.md survives a resumed mirror"
[ ! -e "$RESUME_DIR/tests/test_mergepath_playground.sh" ] \
  && pass "resumed mirror still removes the playground orphan" \
  || fail "playground orphan survives a resumed mirror"

# Dangling symlink: -e is false for these, so the removal must test -L too.
ln -s /nonexistent-target "$RESUME_DIR/CONTEXT.md"
rc="$(run_remove_orphans "$RESUME_DIR")"
{ [ "$rc" -eq 0 ] && [ ! -L "$RESUME_DIR/CONTEXT.md" ]; } \
  && pass "resumed mirror removes a dangling CONTEXT.md symlink" \
  || fail "dangling CONTEXT.md symlink survives (rc=$rc)"

# Failure propagation: an unremovable stale glossary must fail the helper so
# Stage B aborts instead of continuing with hub-only content in the target.
LOCKED_DIR="$WORKDIR/resumed-locked"
mkdir -p "$LOCKED_DIR"
printf 'stale hub glossary\n' >"$LOCKED_DIR/CONTEXT.md"
chmod 555 "$LOCKED_DIR"
rc="$(run_remove_orphans "$LOCKED_DIR")"
chmod 755 "$LOCKED_DIR"
[ "$rc" -ne 0 ] \
  && pass "unremovable stale CONTEXT.md fails the cleanup (rc=$rc)" \
  || fail "cleanup swallowed the removal failure"

# ---------------------------------------------------------------------------
# Codex P1 on #1056/#1112: `git -C "$source_root" rev-parse HEAD` alone is
# not a valid "source_root is a git repo" test — Git's own repository
# discovery walks UP from a non-git directory and happily resolves against
# an ENCLOSING checkout's .git, so a plain directory nested inside an
# unrelated repo would silently record that ancestor's HEAD as the
# consumer's HUB_REF. Drives bootstrap::_init_target_git directly (same
# sourcing pattern as the live _anchor_insert test above) against a
# source_root that is a non-git dir nested inside an otherwise-unrelated
# git repo, and asserts the ancestor's sha is NOT recorded.
# ---------------------------------------------------------------------------
NESTED_ENCLOSING="$WORKDIR/nested-enclosing-repo"
mkdir -p "$NESTED_ENCLOSING/nested/not-a-repo"
git -C "$NESTED_ENCLOSING" init -q -b main
echo seed >"$NESTED_ENCLOSING/f"
git -C "$NESTED_ENCLOSING" add -A
git -C "$NESTED_ENCLOSING" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "enclosing repo seed"
ENCLOSING_SHA=$(git -C "$NESTED_ENCLOSING" rev-parse HEAD)
NESTED_SOURCE="$NESTED_ENCLOSING/nested/not-a-repo"
NESTED_TARGET="$WORKDIR/nested-target"
mkdir -p "$NESTED_TARGET"
echo seed >"$NESTED_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$NESTED_TARGET" "$NESTED_SOURCE" >/dev/null

nested_subject=$(git -C "$NESTED_TARGET" log -1 --format=%s)
if echo "$nested_subject" | grep -qF "${ENCLOSING_SHA:0:7}"; then
  fail "non-git source_root nested inside an unrelated repo leaked the ancestor's sha: $nested_subject"
else
  pass "non-git source_root nested inside an unrelated repo does not leak the ancestor's sha (#1056 Codex P1)"
fi
[ "$nested_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "nested non-git source_root falls back to the un-attributed subject" \
  || fail "nested non-git source_root subject wrong: $nested_subject"

# ---------------------------------------------------------------------------
# Codex P1 round 2 on #1056/#1112: the toplevel check alone proves source_root
# IS a git repo's own root, not WHICH repo. A clean checkout of a FORK is
# just as validly its own toplevel as canonical mergepath, and the Source:
# trailer hardcodes nathanjohnpayne/mergepath regardless -- so without an
# origin-remote check, a fork-only commit would be attributed to a canonical
# URL that cannot resolve it via `git ls-tree -r "$HUB_REF"`. Asserts a
# source_root that IS its own toplevel but whose origin names a fork does
# NOT get its sha recorded.
# ---------------------------------------------------------------------------
FORK_SOURCE="$WORKDIR/fork-of-mergepath"
mkdir -p "$FORK_SOURCE"
git -C "$FORK_SOURCE" init -q -b main
git -C "$FORK_SOURCE" remote add origin "https://github.com/someone-else/mergepath.git"
echo seed >"$FORK_SOURCE/f"
git -C "$FORK_SOURCE" add -A
git -C "$FORK_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "fork seed"
FORK_SHA=$(git -C "$FORK_SOURCE" rev-parse HEAD)
FORK_TARGET="$WORKDIR/fork-target"
mkdir -p "$FORK_TARGET"
echo seed >"$FORK_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$FORK_TARGET" "$FORK_SOURCE" >/dev/null

fork_subject=$(git -C "$FORK_TARGET" log -1 --format=%s)
if echo "$fork_subject" | grep -qF "${FORK_SHA:0:7}"; then
  fail "a fork's own sha (non-canonical origin) was recorded as HUB_REF: $fork_subject"
else
  pass "a source_root whose origin is a fork does not get its sha recorded as HUB_REF (#1056 Codex P1 round 2)"
fi
[ "$fork_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "fork-origin source_root falls back to the un-attributed subject" \
  || fail "fork-origin source_root subject wrong: $fork_subject"

# ---------------------------------------------------------------------------
# Codex P2 on #1112 round 3: the round-2 origin check was an unanchored
# suffix glob (`*github.com[:/]nathanjohnpayne/mergepath`), which
# `https://evilgithub.com/nathanjohnpayne/mergepath.git` also satisfies --
# the `*` absorbs "evil" and the rest of the pattern still lines up.
# bootstrap::_resolve_canonical_source_sha now enumerates exact remote
# forms instead, so no prefix can smuggle in an extra hostname segment.
# ---------------------------------------------------------------------------
SPOOF_SOURCE="$WORKDIR/spoofed-hostname-repo"
mkdir -p "$SPOOF_SOURCE"
git -C "$SPOOF_SOURCE" init -q -b main
git -C "$SPOOF_SOURCE" remote add origin "https://evilgithub.com/nathanjohnpayne/mergepath.git"
echo seed >"$SPOOF_SOURCE/f"
git -C "$SPOOF_SOURCE" add -A
git -C "$SPOOF_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "spoofed-hostname seed"
git -C "$SPOOF_SOURCE" update-ref refs/remotes/origin/main HEAD
SPOOF_SHA=$(git -C "$SPOOF_SOURCE" rev-parse HEAD)
SPOOF_TARGET="$WORKDIR/spoof-target"
mkdir -p "$SPOOF_TARGET"
echo seed >"$SPOOF_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$SPOOF_TARGET" "$SPOOF_SOURCE" >/dev/null

spoof_subject=$(git -C "$SPOOF_TARGET" log -1 --format=%s)
[ "$spoof_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "a spoofed hostname suffix-matching 'github.com' does not get its sha recorded (#1056 Codex P2 round 3)" \
  || fail "spoofed-hostname source_root leaked a sha: $spoof_subject (had ${SPOOF_SHA:0:7} available)"

# ---------------------------------------------------------------------------
# Codex P1 on #1112 round 3: a correctly-origined checkout can still carry
# an unpushed local commit on `main` -- checks 1+2 alone would attribute a
# sha the canonical remote (and therefore `git ls-tree -r "$HUB_REF"` run
# elsewhere) has never heard of. Same origin as the successful FAKE_MP path,
# but with NO refs/remotes/origin/* ref created, so HEAD is not contained in
# any remote-tracking ref.
# ---------------------------------------------------------------------------
UNPUSHED_SOURCE="$WORKDIR/unpushed-commit-repo"
mkdir -p "$UNPUSHED_SOURCE"
git -C "$UNPUSHED_SOURCE" init -q -b main
git -C "$UNPUSHED_SOURCE" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
echo seed >"$UNPUSHED_SOURCE/f"
git -C "$UNPUSHED_SOURCE" add -A
git -C "$UNPUSHED_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "unpushed local commit"
UNPUSHED_SHA=$(git -C "$UNPUSHED_SOURCE" rev-parse HEAD)
UNPUSHED_TARGET="$WORKDIR/unpushed-target"
mkdir -p "$UNPUSHED_TARGET"
echo seed >"$UNPUSHED_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$UNPUSHED_TARGET" "$UNPUSHED_SOURCE" >/dev/null

unpushed_subject=$(git -C "$UNPUSHED_TARGET" log -1 --format=%s)
[ "$unpushed_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "an unpushed local HEAD (not in any remote-tracking ref) does not get its sha recorded (#1056 Codex P1 round 3)" \
  || fail "unpushed-commit source_root leaked a sha: $unpushed_subject (had ${UNPUSHED_SHA:0:7} available)"

# ---------------------------------------------------------------------------
# Codex P2 on #1112 round 4: wizard preflight only validates the checkout at
# $SCRIPT_DIR/.. is clean. If BOOTSTRAP_MERGEPATH_ROOT points at a DIFFERENT
# canonical-origin checkout preflight never saw, checks 1-3 alone would still
# accept it -- but Stage B's rsync mirrors that checkout's WORKING-TREE
# bytes (tracked edits included), so a dirty source_root would attribute a
# HEAD whose tree does not match what was actually mirrored. Same origin +
# remote-tracking ref as the successful FAKE_MP path, but with an uncommitted
# tracked edit left in the working tree.
# ---------------------------------------------------------------------------
DIRTY_SOURCE="$WORKDIR/dirty-working-tree-repo"
mkdir -p "$DIRTY_SOURCE"
git -C "$DIRTY_SOURCE" init -q -b main
git -C "$DIRTY_SOURCE" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
echo seed >"$DIRTY_SOURCE/f"
git -C "$DIRTY_SOURCE" add -A
git -C "$DIRTY_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "dirty-tree seed"
git -C "$DIRTY_SOURCE" update-ref refs/remotes/origin/main HEAD
DIRTY_SHA=$(git -C "$DIRTY_SOURCE" rev-parse HEAD)
echo "uncommitted edit" >>"$DIRTY_SOURCE/f"
DIRTY_TARGET="$WORKDIR/dirty-target"
mkdir -p "$DIRTY_TARGET"
echo seed >"$DIRTY_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$DIRTY_TARGET" "$DIRTY_SOURCE" >/dev/null

dirty_subject=$(git -C "$DIRTY_TARGET" log -1 --format=%s)
[ "$dirty_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "a dirty working tree (uncommitted tracked edit) does not get its sha recorded (#1056 Codex P2 round 4)" \
  || fail "dirty-working-tree source_root leaked a sha: $dirty_subject (had ${DIRTY_SHA:0:7} available)"

# ---------------------------------------------------------------------------
# CodeRabbit on #1112 round 5: rsync mirrors whatever is physically present
# in source_root regardless of .gitignore, but a bare `git status
# --porcelain` (no --ignored) does not report a gitignored-but-present file
# as dirty. Same origin + remote-tracking ref as the successful FAKE_MP
# path, tracked tree otherwise clean, but with a gitignored file physically
# present that rsync would still copy.
# ---------------------------------------------------------------------------
IGNORED_SOURCE="$WORKDIR/ignored-file-repo"
mkdir -p "$IGNORED_SOURCE"
git -C "$IGNORED_SOURCE" init -q -b main
git -C "$IGNORED_SOURCE" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
echo seed >"$IGNORED_SOURCE/f"
echo "stray.artifact" >"$IGNORED_SOURCE/.gitignore"
git -C "$IGNORED_SOURCE" add -A
git -C "$IGNORED_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "ignored-file-repo seed"
git -C "$IGNORED_SOURCE" update-ref refs/remotes/origin/main HEAD
IGNORED_SHA=$(git -C "$IGNORED_SOURCE" rev-parse HEAD)
echo "physically present but gitignored" >"$IGNORED_SOURCE/stray.artifact"
IGNORED_TARGET="$WORKDIR/ignored-target"
mkdir -p "$IGNORED_TARGET"
echo seed >"$IGNORED_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$IGNORED_TARGET" "$IGNORED_SOURCE" >/dev/null

ignored_subject=$(git -C "$IGNORED_TARGET" log -1 --format=%s)
[ "$ignored_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "a gitignored-but-present file does not get its sha recorded (#1056 CodeRabbit round 5)" \
  || fail "ignored-file source_root leaked a sha: $ignored_subject (had ${IGNORED_SHA:0:7} available)"

# ---------------------------------------------------------------------------
# Codex P2 on #1112 round 8: --ignored alone over-corrects. A path
# BOOTSTRAP_MIRROR_EXCLUDES already keeps out of the mirror (.DS_Store here)
# can never reach the target regardless of its git status, so treating its
# mere presence as dirty rejects attribution on completely ordinary
# operator checkouts (every macOS Finder-visited directory grows a stray
# .DS_Store). Same source shape as the successful FAKE_MP path, but with a
# mirror-excluded stray file present -- must still get its sha recorded.
# Paired with a second case proving the filter isn't a blanket bypass: a
# stray file that is NOT in the exclude list still blocks attribution.
# ---------------------------------------------------------------------------
EXCLUDED_NOISE_SOURCE="$WORKDIR/excluded-noise-repo"
mkdir -p "$EXCLUDED_NOISE_SOURCE"
git -C "$EXCLUDED_NOISE_SOURCE" init -q -b main
git -C "$EXCLUDED_NOISE_SOURCE" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
echo seed >"$EXCLUDED_NOISE_SOURCE/f"
git -C "$EXCLUDED_NOISE_SOURCE" add -A
git -C "$EXCLUDED_NOISE_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "excluded-noise-repo seed"
git -C "$EXCLUDED_NOISE_SOURCE" update-ref refs/remotes/origin/main HEAD
EXCLUDED_NOISE_SHA=$(git -C "$EXCLUDED_NOISE_SOURCE" rev-parse HEAD)
echo "finder metadata, never mirrored" >"$EXCLUDED_NOISE_SOURCE/.DS_Store"
EXCLUDED_NOISE_TARGET="$WORKDIR/excluded-noise-target"
mkdir -p "$EXCLUDED_NOISE_TARGET"
echo seed >"$EXCLUDED_NOISE_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$EXCLUDED_NOISE_TARGET" "$EXCLUDED_NOISE_SOURCE" >/dev/null

excluded_noise_subject=$(git -C "$EXCLUDED_NOISE_TARGET" log -1 --format=%s)
[ "$excluded_noise_subject" = "Initial commit (bootstrapped from mergepath@${EXCLUDED_NOISE_SHA:0:7})" ] \
  && pass "a mirror-excluded stray file (.DS_Store) does not block attribution (#1056 Codex P2 round 8)" \
  || fail "excluded-noise source_root wrongly blocked attribution: $excluded_noise_subject (expected sha ${EXCLUDED_NOISE_SHA:0:7})"

REAL_NOISE_SOURCE="$WORKDIR/real-noise-repo"
mkdir -p "$REAL_NOISE_SOURCE"
git -C "$REAL_NOISE_SOURCE" init -q -b main
git -C "$REAL_NOISE_SOURCE" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
echo seed >"$REAL_NOISE_SOURCE/f"
git -C "$REAL_NOISE_SOURCE" add -A
git -C "$REAL_NOISE_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "real-noise-repo seed"
git -C "$REAL_NOISE_SOURCE" update-ref refs/remotes/origin/main HEAD
echo "not in any exclude list" >"$REAL_NOISE_SOURCE/genuinely-stray-file.txt"
REAL_NOISE_TARGET="$WORKDIR/real-noise-target"
mkdir -p "$REAL_NOISE_TARGET"
echo seed >"$REAL_NOISE_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$REAL_NOISE_TARGET" "$REAL_NOISE_SOURCE" >/dev/null

real_noise_subject=$(git -C "$REAL_NOISE_TARGET" log -1 --format=%s)
[ "$real_noise_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "the mirror-exclude filter is not a blanket bypass -- a genuinely stray file still blocks attribution" \
  || fail "real-noise source_root wrongly got attribution: $real_noise_subject"

# ---------------------------------------------------------------------------
# CodeRabbit round 8 (re-raise of the round 5 exotic-git-config class): the
# cleanliness check must not trust status.showUntrackedFiles from the
# operator's own gitconfig -- rsync copies whatever is physically present in
# source_root regardless of what `git status` is configured to report, so a
# config that suppresses untracked entries must not make a genuinely stray,
# non-excluded file read as "clean." Same source shape as the real-noise
# case above, but with status.showUntrackedFiles=no set in the source
# repo's own local config.
# ---------------------------------------------------------------------------
SHOW_UNTRACKED_NO_SOURCE="$WORKDIR/show-untracked-no-repo"
mkdir -p "$SHOW_UNTRACKED_NO_SOURCE"
git -C "$SHOW_UNTRACKED_NO_SOURCE" init -q -b main
git -C "$SHOW_UNTRACKED_NO_SOURCE" remote add origin "https://github.com/nathanjohnpayne/mergepath.git"
echo seed >"$SHOW_UNTRACKED_NO_SOURCE/f"
git -C "$SHOW_UNTRACKED_NO_SOURCE" add -A
git -C "$SHOW_UNTRACKED_NO_SOURCE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q -m "show-untracked-no-repo seed"
git -C "$SHOW_UNTRACKED_NO_SOURCE" update-ref refs/remotes/origin/main HEAD
git -C "$SHOW_UNTRACKED_NO_SOURCE" config status.showUntrackedFiles no
echo "not in any exclude list" >"$SHOW_UNTRACKED_NO_SOURCE/genuinely-stray-file.txt"
SHOW_UNTRACKED_NO_TARGET="$WORKDIR/show-untracked-no-target"
mkdir -p "$SHOW_UNTRACKED_NO_TARGET"
echo seed >"$SHOW_UNTRACKED_NO_TARGET/README.md"
BOOTSTRAP_AUTHOR_NAME="test" BOOTSTRAP_AUTHOR_EMAIL="t@t" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/_lib.sh"
  # shellcheck disable=SC1091
  . "$1/scripts/bootstrap/template-mirror.sh"
  bootstrap::_init_target_git "$2" "$3"
' _ "$ROOT" "$SHOW_UNTRACKED_NO_TARGET" "$SHOW_UNTRACKED_NO_SOURCE" >/dev/null

show_untracked_no_subject=$(git -C "$SHOW_UNTRACKED_NO_TARGET" log -1 --format=%s)
[ "$show_untracked_no_subject" = "Initial commit (bootstrapped from mergepath)" ] \
  && pass "status.showUntrackedFiles=no in the source repo's own config does not hide a genuinely stray file from the cleanliness check (#1056 CodeRabbit round 8)" \
  || fail "show-untracked-no source_root wrongly got attribution despite a stray file hidden by ambient config: $show_untracked_no_subject"

# --- summary --------------------------------------------------------------
echo
echo "test_bootstrap_template_mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
