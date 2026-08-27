#!/usr/bin/env bash
# scripts/bootstrap/template-mirror.sh — bootstrap wizard stage B.
# Per #156 sub-B / #204.
#
# Responsibilities (in dispatch order — matches the numbered Step
# comments in bootstrap::stage_template_mirror):
#   1. rsync mergepath's worktree into the new repo's target dir,
#      honoring a curated exclude list that drops mergepath-only files
#      (the playground spec, packaging/, internal screenshots, and the
#      pure-identity BRAND.md / repository-overview.md, etc.), PLUS the
#      hub-only agent docs, whose exclude patterns are derived from the
#      source manifest's doc_ownership inventory on every run rather
#      than restated in the array. A failed derivation aborts the
#      rsync.
#   2. Remove post-rsync orphans the exclude list can't catch.
#   3. Drop mergepath-specific entries from the new repo's
#      .repo-template.yml (the playground spec_test_map + the
#      extra_top_level_dirs guard for mergepath/packaging). Runs BEFORE
#      substitution so the literal `mergepath_playground` key is still
#      findable for yq's delete (#233).
#   4. Apply name substitutions across the documented name-bearing
#      files (via scripts/bootstrap/substitute.sh).
#   5. Scaffold neutral consumer identity docs (#744/#747): write
#      honest "downstream consumer" stubs for the excluded BRAND.md +
#      docs/agents/repository-overview.md, scrub the AGENTS.md
#      "Repository Layout" section that documents the mergepath-only
#      packaging/ dir, scrub the README.md hub identity (the
#      "Reference implementation" tagline + the Key-Files/Directory
#      rows for consumer-excluded surfaces, #747), and reframe the
#      REVIEW_POLICY.md propagation/wave-audit passages as hub-side
#      machinery (#747). Runs after substitution (dispatched as
#      "Step 5b").
#   6. Reset opt-in policy defaults the hub flipped for itself
#      (phase_4b_automation.enabled → false, #628).
#   7. Initialize the new repo's git history with a single commit. When
#      source_root resolves to a canonical mergepath checkout (its own git
#      toplevel, with an `origin` remote naming nathanjohnpayne/mergepath),
#      the subject is "Initial commit (bootstrapped from mergepath@<sha7>)"
#      and the body carries a "Source: .../commit/<sha>" trailer (#1056).
#      Otherwise it falls back to the un-attributed
#      "Initial commit (bootstrapped from mergepath)".
#
# The cross-repo loop update (open a Mergepath-side PR adding the
# new repo to the loop docs in DEPLOYMENT.md + REVIEW_POLICY.md) is
# the LAST step. It's gated on a separate confirmation prompt because
# it writes to mergepath itself, not to the target. Without
# BOOTSTRAP_AUTO_CONFIRM=1 the operator must say yes.
#
# IMPORTANT — this stage does NOT enroll the new repo as a
# .mergepath-sync.yml consumer. The one-time template rsync (step 1)
# and ongoing sync-consumer enrollment are two genuinely separate
# steps; the cross-repo loop update touches only the loop docs. A repo
# that gets only the rsync + loop-doc registration receives none of
# mergepath's post-bootstrap propagation (script/policy fixes, new
# gates, security hardening) and never shows up in the weekly
# propagation-drift sweep. Enrollment requires a facts: block verified
# against the repo's own package.json (frameworks / testing / jsx_in_js
# / ESM-vs-CJS eslint variant) and a canary-first first sync, so it is
# left as an explicit human NEXT STEP emitted by the board-and-summary
# stage rather than auto-performed here. See mergepath#741 (the
# gaycruisebingo gap) and the .mergepath-sync.yml header.
#
# Reads (set by the wizard before dispatch):
#   $TARGET_DIR                Path to the new repo's target dir.
#   $BOOTSTRAP_MERGEPATH_ROOT  Path to mergepath's worktree (the
#                              wizard's own source root). Exported
#                              by the wizard so this stage can find it.
#   $BOOTSTRAP_INPUT_REPO_NAME et al via bootstrap_input <name>.
#
# Side effects via bootstrap::run (the side-effect wrapper that
# honors --dry-run).

set -euo pipefail

# Source the substitution lib. Its location is fixed relative to
# this stage file. The lib also exports the name-bearing files list
# so the rsync stage and the substitution stage agree on what gets
# rewritten.
# shellcheck source=scripts/bootstrap/substitute.sh
. "${BOOTSTRAP_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/substitute.sh"

# Exclude list — single source of truth. Anything we don't want
# propagated to a new repo lives here. Each entry is an rsync
# --exclude pattern (path-relative-to-source, no leading slash).
# See #204 for the rationale on each entry.
#
# Every `class: hub-only` entry in .mergepath-sync.yml's doc_ownership
# inventory is excluded dynamically by bootstrap::_derive_hub_only_excludes;
# do not duplicate those paths in this hand-maintained array. The class
# says the doc never travels, and deriving the rsync exclusions from that
# inventory keeps it the single source of truth. Assertion 4b4 in
# tests/test_bootstrap_template_mirror.sh verifies the derivation stays
# complete and fail-closed (#797 review).
BOOTSTRAP_MIRROR_EXCLUDES=(
  # Repo metadata that should never propagate. Both forms of `.git` are
  # named deliberately (Codex P1 on #1112 round 17): the trailing-slash
  # form matches only a DIRECTORY, so a linked worktree target -- whose
  # `.git` is a regular FILE holding a `gitdir: <path>` pointer -- is not
  # covered by it alone. rsync's own --delete does not touch a destination
  # path matching an active --exclude of EITHER form, so both are required
  # to protect a normal repo's .git/ and a linked worktree's .git file.
  # Reproduced: rsync -a --delete --exclude='.git/' alone deletes a linked
  # worktree's .git file; adding a bare .git exclude preserves it.
  '.git/'
  '.git'
  '.DS_Store'
  'dist/'

  # Mergepath-only vendoring / packaging dirs
  'mergepath/'
  'packaging/'

  # Mergepath-only orchestrator surfaces - must NEVER propagate.
  # The sync-to-downstream and project-doc-sync engines, their manifests, and
  # their paired tests drive propagation OUT to consumers; they are Mergepath-
  # internal and must never ship INTO a freshly bootstrapped repo. A new repo
  # carrying them would (a) ship a manifest naming every private consumer repo,
  # and (b) look like "Mergepath itself" to the consumer-vs-mergepath detection
  # baked into the propagated scripts/ci/check_* wrappers.
  #
  # Each engine is excluded together with its manifest, paired test, and (for
  # sync) its hub-only cron driver - not piecemeal, because the consumer-vs-
  # mergepath detection keys off PAIRS of these files:
  #
  #   * check_sync_manifest + check_export_consumer_facts disambiguate on the
  #     pair (.mergepath-sync.yml + scripts/sync-to-downstream.sh). Dropping the
  #     manifest alone while leaving the engine trips their "manifest missing
  #     but engine present -> mergepath misconfig" FAIL branch - this was the
  #     Codex P1 on #509, which is why #509 shipped only the project-doc
  #     docs/manifest and deferred the engine. With BOTH absent the wrappers
  #     take the clean consumer-SKIP path.
  #   * check_sync_to_downstream keys off the pair (tests/test_sync_to_downstream.sh
  #     + .mergepath-sync.yml); with both absent it SKIPs at the top, before it
  #     would reach the project-doc companion test (tests/test_project_doc_sync.sh).
  #
  # NB: scripts/sync/ and tests/test_sync_overrides.sh are deliberately NOT
  # excluded. The kit-propagated scripts/ci/check_sync_overrides hard-requires
  # that test (it has no consumer-skip path), and the test sources
  # scripts/sync/{validate,apply}-overrides.sh - so all three are load-bearing
  # in a consumer and must keep flowing through the mirror.
  #
  # Sync-to-downstream surface (engine + manifest + paired test + cron driver).
  # weekly-drift-audit.yml is the hub-only cron that runs the engine's --audit
  # across every consumer; it is mergepath-only (a leaf consumer has no
  # downstream to audit), not propagated via the manifest, and would otherwise
  # fail every week in a new repo on the now-absent engine.
  '.mergepath-sync.yml'
  'scripts/sync-to-downstream.sh'
  'tests/test_sync_to_downstream.sh'
  '.github/workflows/weekly-drift-audit.yml'
  # Project-doc-sync surface. The docs/manifest landed in #509:
  # .mergepath-project-docs.yml carries a `path_hint: .` that would resolve a
  # bootstrapped consumer AS the mergepath owner (so project-doc-sync could
  # mirror the consumer's specs/ into docs/projects/mergepath/specs/ or rewrite
  # a Mergepath PRD mirror), and docs/projects/ holds generated PRD/spec mirrors
  # an agent in the consumer would otherwise read as that repo's product context
  # (Codex P2 on #509). The engine + paired test that act on them ship out here.
  '.mergepath-project-docs.yml'
  'docs/projects/'
  'scripts/project-doc-sync.sh'
  'tests/test_project_doc_sync.sh'

  # Local operator state under .claude/
  '.claude/worktrees/'
  '.claude/settings.local.json'
  '.claude/launch.json'

  # Playground spec + test (mergepath-only sandbox)
  'specs/mergepath_playground.md'
  'plans/mergepath-playground.md'

  # Bootstrap consumer-identity spec (#747): describes hub-only bootstrap
  # machinery and maps to the hub-only tests/test_bootstrap_template_mirror.sh
  # in spec_test_map - shipping it without the test reds a consumer's
  # check_spec_test_alignment.
  'specs/bootstrap_consumer_identity.md'

  # Bootstrap source-SHA attribution spec (#1056): same rationale as the
  # consumer-identity spec above, and it links two hub-only agent docs
  # (docs/agents/propagation-ordering.md, docs/agents/bootstrap-runbook.md)
  # that are themselves excluded — shipping it into a consumer would leave
  # both links dangling (Codex P2 on #1112).
  'specs/bootstrap_source_attribution.md'

  # Mergepath-internal policy simulation tool
  'scripts/policy-sim.sh'

  # Wave-audit surface (#662/#663) - hub-only BY DESIGN, excluded as a
  # pair like the engines above: the driver runs one scoped automated
  # review per propagation wave FROM the hub, and its suite exercises
  # watermark tags a consumer never mints. A bootstrapped repo carrying
  # them would run the hub-only suite instead of the intended
  # check_wave_audit consumer SKIP path.
  'scripts/wave-audit.sh'
  'tests/test_wave_audit.sh'

  # #739 canonical-mirror drift triage aid - hub-only, excluded like the
  # wave-audit pair above: the audit reads MACHINE-LOCAL vendor files
  # (~/GitHub/CLAUDE.md, ~/.codex/AGENTS.md) against the mergepath
  # checkout, and its default MERGEPATH_ROOT is the script's own repo
  # root - shipped to a consumer it would resolve the CONSUMER checkout
  # as the canonical source and misreport every annotation. The paired
  # hermetic suite goes with it. scripts/ci/check_audit_canonical_mirrors
  # is deliberately NOT excluded: the mirrored repo_lint.yml wires it as
  # a step, so the wrapper must ship and take its consumer-SKIP path
  # (test + sync-to-downstream marker both absent) - same shape as
  # check_wave_audit.
  'scripts/audit-canonical-mirrors.sh'
  'tests/test_audit_canonical_mirrors.sh'

  # #774 fleet branch-protection audit - hub-only, excluded as a SET
  # (scheduled workflow + auditor + both paired suites) for the same
  # reason as the pairs above. `--fleet` iterates .mergepath-sync.yml,
  # which the orchestrator excludes above, and reads every sibling repo's
  # protection under BRANCH_PROTECTION_AUDIT_TOKEN - an admin-scoped
  # fleet-wide secret a new repo does not have and must not be given.
  # Shipped verbatim the cron would fire every Monday in a bootstrapped
  # repo and fail forever at the missing-secret guard (or, if a
  # same-named secret existed, at the absent manifest). Dropping the
  # workflow without its auditor and suites would leave
  # check_branch_protection_audit's ERROR branch reachable on the hub, so
  # the workflow, auditor, and paired suites travel together.
  # scripts/ci/check_branch_protection_audit is
  # deliberately NOT excluded: the mirrored repo_lint.yml wires it as a
  # step, so the wrapper must ship and take its consumer-SKIP path. That
  # SKIP keys on the scripts/sync-to-downstream.sh hub marker ALONE, NOT on
  # the "wrapped test absent + marker absent" idiom check_wave_audit and
  # check_audit_canonical_mirrors use - excluding a path here stops future
  # seeding but does not scrub the repos bootstrapped before the exclusion,
  # and gaycruisebingo still carries part of this hub-only set.
  '.github/workflows/branch-protection-audit.yml'
  'scripts/audit-branch-protection.sh'
  'tests/test_audit_branch_protection.sh'
  'tests/test_audit_branch_protection_workflow.sh'

  # Hub identity docs — do NOT duplicate mergepath's self-referential
  # hub identity into a consumer (#744).
  #
  # The `class: hub-only` agent docs are NOT listed here. They are
  # DERIVED from .mergepath-sync.yml's doc_ownership inventory on every
  # run, by bootstrap::_derive_hub_only_excludes below, and appended to
  # this array's patterns in bootstrap::_rsync_template. That class
  # already means "never travels to a consumer"; restating the same
  # docs here made the array a second source of truth that an author
  # had to remember to update, and classifying the next doc hub-only
  # without touching it would have rsynced hub-only content into the
  # next new repo (#797 review). Deriving removes the duplication
  # instead of guarding it: there is now one place to edit, and the
  # inventory is it.
  #
  # What stays hand-listed is what the inventory does NOT imply.
  # BRAND.md and docs/agents/repository-overview.md are excluded while
  # staying `class: per-repo-owned`: each repo legitimately owns its
  # own copy, so the class cannot say "never travels" — but mergepath's
  # copies are 100% hub identity ("the reference implementation", the
  # Playground/Cockpit/Tiebreaker/Checks surfaces), and a lexical
  # mergepath→<repo> swap leaves those self-referential claims intact
  # and FALSE. So they are dropped here and replaced by neutral
  # consumer stubs in bootstrap::_scaffold_consumer_identity (step 5b
  # below), which is also why they are absent from
  # BOOTSTRAP_NAME_BEARING_FILES in substitute.sh. (The mixed doc
  # .ai_context.md keeps its shared content and is fixed at the
  # mergepath source, not here; the AGENTS.md packaging note is
  # scrubbed in step 5b.)
  #
  # NB: ai_agent_tooling_standard.md is deliberately NOT excluded by
  # either route — it is the methodology-neutral Standard the consumer
  # FOLLOWS (it correctly names mergepath as the reference
  # implementation and is not name-substituted, so it stays true in a
  # consumer), and README.md / .ai_context.md still link to it
  # (Codex #746).
  'BRAND.md'
  'docs/agents/repository-overview.md'

  # CONTEXT.md is the hub glossary (#864): its opening line states hub
  # identity ("the reference implementation ... hub of the fleet") that
  # is FALSE in a consumer, and its definitions point at the propagation
  # manifest this stage deliberately strips. It is a root file outside
  # docs/agents/, so the doc_ownership derivation cannot carry it — it
  # is hand-listed here. Unlike BRAND.md above it gets NO consumer stub:
  # a glossary is wholly hub-authored voice, and there is no neutral
  # consumer stub worth generating. Consumers author their own glossary
  # if they want one.
  'CONTEXT.md'

  # Screenshots — internal evidence, not template content
  'bugs/screenshots/'
  '.github/screenshots/'

  # State files from prior wizard runs (when re-running into the
  # same target dir). The sidecars are separate on-disk files, not part of
  # .bootstrap-state's own bytes (Codex P1 on #1112 round 12): plain
  # `rsync --delete` (round 9) protects only paths matching an active
  # --exclude, so without their own entries here it deletes them as
  # ordinary receiver-only residue -- losing .warnings drops the final
  # warning summary, and losing .checkpoints makes a later GitHub-infra
  # retry forget it already performed an irreversible `gh repo create`.
  '.bootstrap-log'
  '.bootstrap-state'
  '.bootstrap-state.warnings'
  '.bootstrap-state.checkpoints'
)

# Entries of BOOTSTRAP_MIRROR_EXCLUDES that bootstrap::_reconcile_excluded_residue
# (#1112 round 10) must never remove from the target, even though they are
# excluded from the rsync transfer: the target's own repository, the
# wizard's own resume bookkeeping, and operator-local .claude/ config the
# OPERATOR may have set up for the target itself between a stage failure
# and --resume. Everything else in BOOTSTRAP_MIRROR_EXCLUDES is mergepath-
# hub-only content that must never exist in a consumer under any
# circumstance, so stale residue at those paths is always safe to remove.
BOOTSTRAP_MIRROR_RECONCILE_PROTECTED=(
  '.git/'
  '.git'
  '.bootstrap-log'
  '.bootstrap-state'
  '.bootstrap-state.warnings'
  '.bootstrap-state.checkpoints'
  '.claude/worktrees/'
  '.claude/settings.local.json'
  '.claude/launch.json'
)

# Entries of BOOTSTRAP_MIRROR_EXCLUDES that bootstrap::_resolve_canonical_source_sha
# (#1112 round 11) must NEVER excuse from the cleanliness check, even though
# they are excluded from the rsync transfer: an uncommitted edit to one of
# these changes what Stage B actually MIRRORS (bootstrap::_derive_hub_only_excludes
# reads .mergepath-sync.yml's doc_ownership at mirror time), so an attributed
# HEAD would not match the tree that was actually produced. This is narrower
# than "is a file ever read by bootstrap" -- only files whose CONTENT decides
# what gets mirrored, not the file's own bytes reaching the target, qualify.
BOOTSTRAP_MIRROR_CONTROL_FILES=(
  '.mergepath-sync.yml'
)

# Files that rsync leaves behind because they don't match an exclude
# pattern but shouldn't ship to a new repo. Post-mirror cleanup.
BOOTSTRAP_POST_MIRROR_REMOVE=(
  tests/test_mergepath_playground.sh
  # CONTEXT.md is also excluded from the rsync above; listing it here too
  # closes the resumed-mirror gap (#864): --exclude only skips the transfer,
  # so a receiver populated by an earlier or interrupted Stage B would keep
  # its stale hub-glossary copy without this removal.
  CONTEXT.md
)

# Directories to remove ONLY if they end up empty after the
# rsync + orphan cleanup. Some sub-dirs of bugs/ or similar only
# existed to hold screenshots; if those got excluded, the parent
# is empty and should be tombstoned.
BOOTSTRAP_POST_MIRROR_RMDIR_IF_EMPTY=(
  bugs
)

bootstrap::stage_template_mirror() {
  bootstrap::stage_banner "template-mirror"

  local target
  target=$(bootstrap::_resolve_target_dir)
  local source_root
  source_root=$(bootstrap::_resolve_source_root)

  if [ ! -d "$source_root" ]; then
    bootstrap::err "template-mirror: source root not found: $source_root"
    return 1
  fi

  # Stage-level failure propagation. Each step's rc is captured into
  # $step_rc and we short-circuit return on the first non-zero — without
  # this, `set -e` inside the stage is NOT sufficient to stop the run,
  # because the dispatch in scripts/bootstrap-new-repo.sh invokes the
  # stage as `"$fn" || stage_rc=$?` (which disables -e inside the called
  # function under bash). Codex caught this on round 1 of #233 P1.
  #
  # Steps that return non-zero are treated as fatal for the stage. The
  # cross-repo loop step is intentionally tolerant of "no anchors yet"
  # (it returns 0 with a warning), so it's safe to keep here.
  local step_rc=0

  # Step 1: rsync mergepath → target with excludes.
  bootstrap::_rsync_template "$source_root" "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: rsync step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 2: post-mirror orphan cleanup.
  bootstrap::_remove_orphans "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: orphan-removal step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 3: drop mergepath-specific .repo-template.yml entries.
  # MUST run BEFORE substitution so the playground key (literally
  # `mergepath_playground`) is still findable — substitution would
  # rename it to `<new-repo>_playground` and yq's delete would miss.
  # CodeRabbit + Codex both caught this on round 1 of #233.
  bootstrap::_clean_repo_template_yml "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: .repo-template.yml cleanup failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 4: apply name substitutions across the name-bearing files
  # (now that the playground key is gone from .repo-template.yml).
  bootstrap::apply_name_substitutions "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: substitution step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 5b: scaffold neutral consumer identity docs (#744/#747). The
  # rsync excluded BRAND.md + docs/agents/repository-overview.md (pure
  # mergepath identity) via BOOTSTRAP_MIRROR_EXCLUDES, and every
  # `class: hub-only` agent doc via the exclusions derived from
  # doc_ownership (do not restate that set as a count here — it grows
  # whenever a doc is classified hub-only); this writes honest
  # consumer stubs for the former, scrubs the AGENTS.md packaging
  # note (packaging/ is a mergepath-only dir, also excluded), scrubs
  # the README.md hub identity + dead Key-Files rows (#747), and
  # reframes REVIEW_POLICY.md's wave-audit passage as hub-side (#747).
  # Runs AFTER substitution so the scrubs see the substituted text.
  bootstrap::_scaffold_consumer_identity "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: consumer-identity scaffold failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 5c: verify the new repo actually carries the canonical agent
  # docs and reads the shared rules ahead of its local overlay (#780).
  # Runs AFTER the identity scaffold because that step rewrites
  # AGENTS.md, and the ordering assertion must see the final file.
  bootstrap::_verify_canonical_agent_docs "$target" "$source_root" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: canonical agent-doc verification failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 5: reset opt-in policy defaults the hub has flipped for itself.
  # phase_4b_automation.enabled: true on the hub (#628) must NOT opt every
  # future bootstrapped repo into local reviewer-CLI automation - a new
  # repo opts in explicitly after validating plan-logins on its operator
  # machine (Codex P2 on #628). Scoped to the parent block's direct child
  # so codex.enabled / accounting.enabled are untouched.
  bootstrap::_reset_phase_4b_enabled "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: phase-4b default reset failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 5: initialize git history.
  bootstrap::_init_target_git "$target" "$source_root" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: git-init step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 6: cross-repo loop update. Writes to mergepath itself, so
  # gated on a confirmation prompt. Returns 0 (with a warning) when
  # the anchors aren't present yet — that's a soft no-op, not a
  # failure. Real failures (e.g., dirty mergepath worktree mid-stage)
  # do return non-zero and abort the stage.
  bootstrap::_cross_repo_loop_update "$source_root" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: cross-repo loop step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  bootstrap::record_stage "template-mirror"
  return 0
}

# --- internal helpers -------------------------------------------------------

bootstrap::_resolve_target_dir() {
  # The wizard sets $TARGET_DIR as a script-global. Stage functions
  # run in the same shell, so it's visible. Echo for symmetry with
  # _resolve_source_root.
  echo "${TARGET_DIR:?TARGET_DIR not set by wizard}"
}

bootstrap::_resolve_source_root() {
  # Prefer BOOTSTRAP_MERGEPATH_ROOT (explicit, set by the wizard).
  # Fall back to walking up from $SCRIPT_DIR/.. since the wizard
  # lives at scripts/bootstrap-new-repo.sh in mergepath's worktree.
  if [ -n "${BOOTSTRAP_MERGEPATH_ROOT:-}" ]; then
    echo "$BOOTSTRAP_MERGEPATH_ROOT"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ]; then
    (cd "$SCRIPT_DIR/.." && pwd)
    return 0
  fi
  # Last resort: walk up from this stage file.
  (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

bootstrap::_reset_phase_4b_enabled() {
  local target=$1
  local policy="$target/.github/review-policy.yml"
  [ -f "$policy" ] || return 0
  # Dry-run contract (#628 Codex P2): every mirror step is a no-op under
  # --dry-run; this rewrite must not mutate an existing target policy.
  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::log "dry-run: would reset phase_4b_automation.enabled to false in $policy"
    return 0
  fi
  # FAIL CLOSED (#628 CodeRabbit Major): if the block exists but the awk
  # never rewrites its direct-child enabled key (key renamed, re-indented,
  # block reshaped upstream), a silent pass-through would ship
  # enabled: true downstream - the one outcome this helper exists to
  # prevent. A policy with NO phase_4b_automation block passes: an absent
  # parent key reads as disabled (the documented default). A block whose
  # enabled key is absent also fails here - over-strict, but fail-closed:
  # a reshape upstream must be looked at, not guessed about.
  if ! awk '
    /^phase_4b_automation:/ { sawblk=1; inblk=1; print; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk && !done && /^  enabled:/ {
      print "  # Reset to the manual-handoff default by the bootstrap mirror"
      print "  # (#628): a new repo opts in to local reviewer-CLI automation"
      print "  # explicitly, after validating plan-logins on its own machine."
      print "  enabled: false"
      done=1; next
    }
    { print }
    END { exit (sawblk && !done) ? 1 : 0 }
  ' "$policy" > "$policy.bootstrap-tmp"; then
    rm -f "$policy.bootstrap-tmp"
    bootstrap::err "phase-4b reset: phase_4b_automation block present but its enabled key was not found/reset in $policy (reshaped upstream?); failing closed rather than mirroring an opted-in policy"
    return 1
  fi
  if ! mv "$policy.bootstrap-tmp" "$policy"; then
    rm -f "$policy.bootstrap-tmp"
    bootstrap::err "phase-4b reset: failed to move the scrubbed copy over $policy; failing closed"
    return 1
  fi
}

# Scaffold neutral consumer identity docs and scrub mergepath-only
# identity from shared docs (#744/#747). The rsync excluded BRAND.md +
# docs/agents/repository-overview.md (pure mergepath identity) via
# BOOTSTRAP_MIRROR_EXCLUDES, and every `class: hub-only` agent doc via
# the exclusions derived from doc_ownership (the inventory is the
# single source of truth for that set — it is deliberately not
# restated as a count here); this writes honest consumer stubs for the
# two excluded identity docs and removes the AGENTS.md "Repository Layout"
# section that documents the mergepath-only `packaging/` dir. The mixed
# doc .ai_context.md keeps its shared content — its one false line is
# fixed at the mergepath source, so it flows through substitution
# honestly and needs no consumer-side edit here.
#
# #747 extends the same pass to the two remaining mixed docs:
#   * README.md IS name-substituted, but the substituted copy still
#     carries the hub tagline ("Reference implementation of the AI
#     Agent Tooling Standard"), the BRAND umbrella-vocabulary framing
#     (Playground/Cockpit/Tiebreaker/Checks), and Key-Files/Directory
#     rows for surfaces excluded from every consumer (the playground,
#     scripts/policy-sim.sh, the sync manifest). Those are rewritten or
#     dropped in place; the genuinely-shared content (agent reading
#     order, review-policy pointer, Firebase auth, directory table)
#     flows through untouched. Fails closed if a hub marker survives.
#   * REVIEW_POLICY.md is copied verbatim (not name-substituted). Its
#     § Phase 3.5 wave-audit paragraph describes hub-only machinery
#     (scripts/wave-audit.sh, the watermark tags) and hard-links
#     docs/agents/propagation-ordering.md — excluded from consumers.
#     The paragraph is replaced by a short hub-side pointer, and a
#     consumer note after the Phase 3.5 heading frames the remaining
#     hub-script references (sync-to-downstream.sh, the manifest) as
#     living on mergepath, per the #746 "true after substitution"
#     lesson. Marker-gated and fail-closed, like the AGENTS.md scrub.
bootstrap::_scaffold_consumer_identity() {
  local target=$1
  local repo_name Repo_Name
  repo_name=$(bootstrap_input repo_name)
  Repo_Name=$(bootstrap::_titlecase_first "$repo_name")
  local hub_url="https://github.com/nathanjohnpayne/mergepath"

  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::log "dry-run: would scaffold neutral BRAND.md + docs/agents/repository-overview.md, scrub the AGENTS.md 'Repository Layout' (packaging/) section, scrub the README.md hub identity + dead Key-Files rows, and reframe the REVIEW_POLICY.md wave-audit passage as hub-side in $target"
    return 0
  fi

  # Neutral BRAND.md — a consumer's brand is its own product, not
  # mergepath's hub surfaces. Frame the repo as a downstream consumer
  # and invite the operator to replace this stub.
  mkdir -p "$target"
  cat > "$target/BRAND.md" <<EOF
# $Repo_Name — brand vocabulary

**$Repo_Name** is a downstream consumer of the [mergepath]($hub_url) AI-agent tooling template. mergepath is the reference implementation of the AI Agent Tooling Standard; **$Repo_Name is not** — it inherits mergepath's agent tooling (the review policy, CI checks, and bootstrap-provisioned workflows) via a one-time template bootstrap and, once enrolled as a sync consumer, ongoing propagation.

This file is a stub. Replace it with $Repo_Name's own brand vocabulary — the product surfaces, naming, and terminology specific to this project.
EOF

  # Neutral repository overview — honest "consumer of mergepath" framing,
  # no Playground / "reference implementation" claims.
  mkdir -p "$target/docs/agents"
  cat > "$target/docs/agents/repository-overview.md" <<EOF
# Repository Overview

**$Repo_Name** is a downstream **consumer** of the [mergepath]($hub_url) AI-agent tooling template. It inherits mergepath's agent tooling — the review policy, CI checks, and bootstrap-provisioned workflows — and is **not** the reference implementation of the AI Agent Tooling Standard (that is mergepath).

Replace this section with a project-specific overview of $Repo_Name: its purpose, primary stack, and the agent's role in maintaining it. See \`BRAND.md\` for repo vocabulary.
EOF

  # Scrub the AGENTS.md "## Repository Layout" section: it exists solely
  # to justify the mergepath-only `packaging/` dir (excluded from every
  # consumer), so in a consumer it documents a directory that isn't
  # there. Only act when the packaging marker is present, so an AGENTS.md
  # that has legitimately reshaped this section is left untouched.
  local agents="$target/AGENTS.md"
  if [ -f "$agents" ] && grep -q "placeholder package scaffolds that reserve" "$agents"; then
    if ! awk '
      # Drop lines from the "## Repository Layout" heading up to (but not
      # including) the next top-level "## " heading or EOF.
      /^## Repository Layout[[:space:]]*$/ { drop=1; next }
      drop && /^## / { drop=0 }
      drop { next }
      { print }
    ' "$agents" > "$agents.bootstrap-tmp"; then
      rm -f "$agents.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: failed to scrub the AGENTS.md Repository Layout section in $agents"
      return 1
    fi
    # Fail closed if the packaging marker survived the scrub (the
    # section was reshaped so the heading match missed it) — better to
    # halt than ship an AGENTS.md documenting a non-existent dir.
    if grep -q "placeholder package scaffolds that reserve" "$agents.bootstrap-tmp"; then
      rm -f "$agents.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: AGENTS.md packaging note survived the Repository-Layout scrub (section reshaped upstream?); failing closed"
      return 1
    fi
    if ! mv "$agents.bootstrap-tmp" "$agents"; then
      rm -f "$agents.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: failed to move the scrubbed copy over $agents; failing closed"
      return 1
    fi
    bootstrap::log "scrubbed the mergepath-only Repository Layout (packaging/) section from AGENTS.md"
  fi

  # Scrub the README.md hub identity (#747). README.md IS
  # name-substituted (so this runs post-substitution and every pattern
  # below is substitution-safe: none contains a `mergepath` token), but
  # the substituted copy still asserts the hub's identity. Rewrite the
  # false claims and drop the Key-Files/Directory rows that point at
  # consumer-excluded surfaces; everything else flows through. The
  # transform is a per-line no-op when a marker is absent, and the
  # forbidden-marker check below fails closed if a hub claim survives
  # in a form the transform no longer matches (README reshaped
  # upstream) — better to halt than mint a false consumer README.
  local readme="$target/README.md"
  if [ -f "$readme" ]; then
    if ! awk -v hub_url="$hub_url" '
      # Tagline: the reference-implementation claim is false for a
      # consumer; replace with honest downstream framing.
      /Reference implementation of the AI Agent Tooling Standard/ {
        print "**A downstream consumer of the [mergepath](" hub_url ") AI-agent tooling template.**"
        next
      }
      # Intro paragraph: the consumer BRAND.md is a neutral stub, not
      # the hub surface vocabulary. Keep the leading sentence(s) and
      # rewrite the "See BRAND.md ..." tail; if the tail moved, the
      # marker survives and the forbidden check fails closed.
      /umbrella vocabulary \(Playground, Cockpit, Tiebreaker, Checks\)/ {
        sub(/ See \[`BRAND\.md`\]\(BRAND\.md\).*$/, " See [`BRAND.md`](BRAND.md) for this repo\047s brand vocabulary (a bootstrap stub until replaced).")
        print
        next
      }
      # Key-Files row for BRAND.md: point at the stub, not the hub
      # umbrella vocabulary.
      /umbrella vocabulary \(surfaces, reserved names, naming history\)/ {
        print "| `BRAND.md` | Project brand vocabulary (bootstrap stub — replace with this repo\047s own) |"
        next
      }
      # Key-Files / Directory-Structure rows for consumer-excluded hub
      # surfaces: the playground, policy-sim.sh, the sync manifest, and
      # the reserved-surfaces directory. Dead rows in a consumer.
      /playground\/index\.html/ { next }
      /scripts\/policy-sim\.sh/ { next }
      /Propagation manifest for synced/ { next }
      /Playground and reserved slots/ { next }
      { print }
    ' "$readme" > "$readme.bootstrap-tmp"; then
      rm -f "$readme.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: failed to scrub the README.md hub identity in $readme"
      return 1
    fi
    local readme_marker
    for readme_marker in \
      'Reference implementation of the AI Agent Tooling Standard' \
      'playground/index.html' \
      'policy-sim.sh' \
      'Mergepath Playground' \
      'Playground and reserved slots' \
      'umbrella vocabulary' \
      'Propagation manifest'; do
      if grep -qF "$readme_marker" "$readme.bootstrap-tmp"; then
        rm -f "$readme.bootstrap-tmp"
        bootstrap::err "consumer-identity scaffold: README.md hub marker '$readme_marker' survived the scrub (README reshaped upstream?); failing closed"
        return 1
      fi
    done
    if ! mv "$readme.bootstrap-tmp" "$readme"; then
      rm -f "$readme.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: failed to move the scrubbed copy over $readme; failing closed"
      return 1
    fi
    bootstrap::log "scrubbed the mergepath hub identity + dead Key-Files rows from README.md"
  fi

  # Reframe REVIEW_POLICY.md's propagation/wave passages as hub-side
  # machinery (#747). REVIEW_POLICY.md is copied verbatim (NOT
  # name-substituted), so its mergepath references stay true — but the
  # § Phase 3.5 wave-audit paragraph describes machinery only the hub
  # runs (scripts/wave-audit.sh, the watermark tags) and hard-links
  # docs/agents/propagation-ordering.md, which is excluded from every
  # consumer (#744). Replace that paragraph with a hub-side pointer and
  # insert a consumer note after the Phase 3.5 heading framing the
  # remaining hub-script references (sync-to-downstream.sh, the
  # manifest) as living on mergepath — while distinguishing
  # scripts/audit-propagation-lane.sh, which IS synced into every
  # consumer (its check_propagation_lane_audit wrapper hard-requires
  # it); only its live fleet-audit mode is hub-side. Marker-gated: only
  # act when the wave-audit paragraph is present, so a legitimately
  # reshaped policy is left untouched; inside the gate, fail closed if
  # either edit missed (heading or paragraph reshaped without the
  # marker moving). The replacement consumes the whole paragraph
  # through its terminating blank line OR the next heading line,
  # whichever comes first — a heading immediately following the
  # paragraph with no blank-line separator is still valid Markdown,
  # and consuming only up to the blank line would swallow it too. A
  # hard-wrapped upstream variant cannot leak continuation lines past
  # the marker check either way (which only sees the marker's own
  # line), and the post-transform Phase 4 heading assertion below
  # fails closed if the heading itself ever got swallowed.
  local policy_doc="$target/REVIEW_POLICY.md"
  local wave_marker='**Wave audit (#662).**'
  local phase4_marker='### Phase 4: External Review'
  if [ -f "$policy_doc" ] && grep -qF "$wave_marker" "$policy_doc"; then
    # Recorded pre-transform so the post-transform assertion below only
    # fires when the heading was actually there to lose — it's the
    # concrete regression check for the paragraph-consumer swallowing a
    # heading that follows with no blank-line separator.
    local had_phase4_heading=0
    if grep -qF "$phase4_marker" "$policy_doc"; then
      had_phase4_heading=1
    fi
    if ! awk -v hub_url="$hub_url" '
      in_wave_para {
        # Consume the wave-audit paragraph through its terminating
        # blank line. The repo enforces soft-wrap (one physical line
        # per paragraph), so this is normally a single next; it exists
        # so a hard-wrapped variant cannot leak continuation lines.
        if ($0 ~ /^[[:space:]]*$/) { in_wave_para = 0; print; next }
        # A heading immediately following the paragraph (no blank
        # line before it) also terminates consumption — print it and
        # stop, rather than swallowing it as a "continuation line".
        if ($0 ~ /^#/) { in_wave_para = 0; print; next }
        next
      }
      /^### Phase 3\.5: Propagation PR review lane[[:space:]]*$/ {
        print
        print ""
        print "> **Consumer note (hub-side machinery):** the propagation tooling this section references — `scripts/sync-to-downstream.sh`, the `.mergepath-sync.yml` manifest, `scripts/wave-audit.sh`, and `docs/agents/propagation-ordering.md` — lives in the [mergepath hub repo](" hub_url "), not in this repository. (`scripts/audit-propagation-lane.sh` is different: this repo carries a synced copy for its CI checks, while the live fleet-audit mode runs from the hub.) This repo is on the receiving end: once enrolled as a sync consumer — enrollment in the hub\047s manifest is a separate post-bootstrap step — the hub opens propagation PRs here, and the lane recognition below runs in this repo\047s synced `pr-review-policy.yml`."
        next
      }
      /^\*\*Wave audit \(#662\)\.\*\*/ {
        print "**Wave audit (hub-side).** The wave-level fresh-eyes audit is mergepath hub machinery: `scripts/wave-audit.sh` runs from the mergepath repo against the wave canary, not in this consumer — once this repository is enrolled as a sync consumer it receives the resulting fan-out mirror PRs, which merge on consumer CI plus the lane\047s byte-verification. The full procedure lives in mergepath\047s `docs/agents/propagation-ordering.md` § Wave audit."
        in_wave_para = 1
        next
      }
      { print }
    ' "$policy_doc" > "$policy_doc.bootstrap-tmp"; then
      rm -f "$policy_doc.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: failed to reframe the REVIEW_POLICY.md wave-audit passage in $policy_doc"
      return 1
    fi
    if grep -qF "$wave_marker" "$policy_doc.bootstrap-tmp"; then
      rm -f "$policy_doc.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: REVIEW_POLICY.md wave-audit paragraph survived the reframe (paragraph reshaped upstream?); failing closed"
      return 1
    fi
    if ! grep -qF 'Consumer note (hub-side machinery)' "$policy_doc.bootstrap-tmp"; then
      rm -f "$policy_doc.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: REVIEW_POLICY.md Phase 3.5 heading not found for the consumer note (section reshaped upstream?); failing closed"
      return 1
    fi
    if [ "$had_phase4_heading" -eq 1 ] && ! grep -qF "$phase4_marker" "$policy_doc.bootstrap-tmp"; then
      rm -f "$policy_doc.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: REVIEW_POLICY.md '$phase4_marker' heading vanished after the wave-audit reframe (swallowed by the paragraph consumer, or section reshaped upstream?); failing closed"
      return 1
    fi
    if ! mv "$policy_doc.bootstrap-tmp" "$policy_doc"; then
      rm -f "$policy_doc.bootstrap-tmp"
      bootstrap::err "consumer-identity scaffold: failed to move the reframed copy over $policy_doc; failing closed"
      return 1
    fi
    bootstrap::log "reframed the REVIEW_POLICY.md wave-audit passage as hub-side machinery"
  fi
}

# Verify the bootstrapped repo carries the canonical agent docs and
# reads the shared rules BEFORE its local operating-rules overlay (#780).
#
# Two assertions, both fail-closed:
#
#   1. Every backed `class: canonical` agent doc in the SOURCE manifest
#      landed. The required set is derived on every run rather than
#      copied into this script, so backing a pending document expands the
#      bootstrap assertion automatically. The rsync copies them by
#      default, so a failure here means someone added an exclude pattern
#      that swallows a canonical doc.
#   2. AGENTS.md references docs/agents/shared-operating-rules.md, and
#      does so BEFORE its reference to docs/agents/operating-rules.md.
#      The order is the point: the shared file is the fleet-wide core
#      and the local file is the per-repo overlay, so an agent that
#      reads the index top-down must meet the shared rules first. An
#      AGENTS.md that links the shared file only after (or not at all)
#      leaves the new repo's agents on the overlay alone.
#
# The two path strings do not overlap as substrings
# ("docs/agents/shared-operating-rules.md" does not contain
# "docs/agents/operating-rules.md"), so a fixed-string line match is
# unambiguous.
bootstrap::_verify_canonical_agent_docs() {
  local target=$1
  local source_root=${2:-${BOOTSTRAP_MERGEPATH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}

  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::log "dry-run: would verify the canonical agent docs landed in $target and that AGENTS.md reads the shared operating rules before the local overlay"
    return 0
  fi

  local manifest="$source_root/.mergepath-sync.yml"
  if [ ! -f "$manifest" ]; then
    bootstrap::err "source .mergepath-sync.yml missing; cannot derive the canonical agent-doc set"
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    bootstrap::err "yq is required to derive canonical agent docs from .mergepath-sync.yml"
    return 2
  fi
  if ! yq -e '.doc_ownership | tag == "!!seq"' "$manifest" >/dev/null 2>&1; then
    bootstrap::err "source .mergepath-sync.yml has no valid doc_ownership list; cannot verify canonical agent docs"
    return 1
  fi

  local invalid_pending
  if ! invalid_pending=$(yq -r '.doc_ownership[] | select(has("pending_manifest") and ((.pending_manifest | tag) != "!!bool")) | .path' "$manifest" 2>&1); then
    bootstrap::err "could not validate pending_manifest types in source .mergepath-sync.yml: $invalid_pending"
    return 1
  fi
  if [ -n "$invalid_pending" ]; then
    bootstrap::err "source .mergepath-sync.yml uses a non-boolean pending_manifest for:$invalid_pending — refusing to let a truthy-looking string change the canonical agent-doc set"
    return 1
  fi

  local canonical_docs
  if ! canonical_docs=$(yq -r '.doc_ownership[] | select(.class == "canonical" and ((.pending_manifest // false) != true)) | .path' "$manifest" 2>&1); then
    bootstrap::err "could not derive canonical agent docs from source .mergepath-sync.yml: $canonical_docs"
    return 1
  fi
  if [ -z "$canonical_docs" ]; then
    bootstrap::err "source .mergepath-sync.yml declares no backed canonical agent docs; refusing a vacuous bootstrap verification"
    return 1
  fi

  local missing="" doc
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    [ -f "$target/$doc" ] || missing="$missing $doc"
  done <<< "$canonical_docs"
  if [ -n "$missing" ]; then
    bootstrap::err "canonical agent docs missing from the mirrored repo:$missing — these are 'class: canonical' in .mergepath-sync.yml's doc_ownership inventory and every new repo must carry them. Check BOOTSTRAP_MIRROR_EXCLUDES for a pattern that swallows them, and check that doc_ownership does not also classify them hub-only (that class is derived into the mirror exclusions)."
    return 1
  fi

  local mismatched="" source_mode target_mode
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    if [ -L "$target/$doc" ]; then
      mismatched="$mismatched $doc(symlink)"
      continue
    fi
    if [ ! -f "$source_root/$doc" ] || ! cmp -s -- "$source_root/$doc" "$target/$doc"; then
      mismatched="$mismatched $doc(content)"
      continue
    fi
    source_mode=$(git -C "$source_root" ls-files -s -- "$doc" 2>/dev/null | awk 'NR == 1 { print $1 }')
    case "$source_mode" in
      100644|100755) ;;
      *) mismatched="$mismatched $doc(source-mode:${source_mode:-untracked})"; continue ;;
    esac
    target_mode=100644
    [ -x "$target/$doc" ] && target_mode=100755
    [ "$source_mode" = "$target_mode" ] || mismatched="$mismatched $doc(mode:$source_mode->$target_mode)"
  done <<< "$canonical_docs"
  if [ -n "$mismatched" ]; then
    bootstrap::err "canonical agent docs differ from the source checkout:$mismatched — an exclusion may have left stale receiver content, or rsync failed to preserve the source Git mode"
    return 1
  fi

  local agents_md="$target/AGENTS.md"
  if [ ! -f "$agents_md" ]; then
    bootstrap::err "AGENTS.md missing from the mirrored repo; cannot verify the agent-docs reading order"
    return 1
  fi

  local shared_pos local_pos shared_line shared_col local_line local_col
  shared_pos=$(bootstrap::_agents_index_link_position "$agents_md" 'docs/agents/shared-operating-rules.md' || true)
  local_pos=$(bootstrap::_agents_index_link_position "$agents_md" 'docs/agents/operating-rules.md' || true)

  if [ -z "$shared_pos" ]; then
    bootstrap::err "AGENTS.md does not reference docs/agents/shared-operating-rules.md — the new repo would ship the shared rulebook with nothing pointing at it. Add it to the AGENTS.md reading order at the mergepath source."
    return 1
  fi
  if [ -z "$local_pos" ]; then
    bootstrap::err "AGENTS.md does not reference docs/agents/operating-rules.md — the new repo would ship the repo-local overlay with nothing pointing at it. Add it to the AGENTS.md reading order after docs/agents/shared-operating-rules.md at the mergepath source."
    return 1
  fi
  shared_line=${shared_pos%%:*}
  shared_col=${shared_pos#*:}
  local_line=${local_pos%%:*}
  local_col=${local_pos#*:}
  if [ "$shared_line" -gt "$local_line" ] || { [ "$shared_line" -eq "$local_line" ] && [ "$shared_col" -ge "$local_col" ]; }; then
    bootstrap::err "AGENTS.md lists docs/agents/operating-rules.md (line $local_line, column $local_col) BEFORE docs/agents/shared-operating-rules.md (line $shared_line, column $shared_col) — the shared canonical rules must come first, with the per-repo overlay after. Fix the ordering at the mergepath source."
    return 1
  fi

  bootstrap::log "canonical agent docs present and AGENTS.md reads the shared operating rules before the local overlay"
  return 0
}

# Print the line:column of an actual Markdown link in AGENTS.md's visible
# Sections list. Raw path strings in comments, prose, or examples are not
# reading-order entries and must not mask a reversed index.
bootstrap::_agents_index_link_position() {
  local agents_md=$1 target=$2
  awk -v target="$target" '
    function visible_html(s, out, at, end_at) {
      out = ""
      while (1) {
        if (in_comment) {
          end_at = index(s, "-->")
          if (!end_at) return out
          s = substr(s, end_at + 3)
          in_comment = 0
        }
        at = index(s, "<!--")
        if (!at) return out s
        out = out substr(s, 1, at - 1)
        s = substr(s, at + 4)
        in_comment = 1
      }
    }
    {
      line = visible_html($0)
      if (line ~ /^##[[:space:]]+Sections([[:space:]]|$)/) { in_sections = 1; next }
      if (in_sections && line ~ /^##[[:space:]]+/) exit
      if (!in_sections || line !~ /^[[:space:]]*([0-9]+\.|[-+*])[[:space:]]+/) next
      plain = "](" target ")"
      angled = "](<" target ">)"
      col = index(line, plain)
      if (col) { printf "%d:%d\n", NR, col + 2; exit }
      col = index(line, angled)
      if (col) { printf "%d:%d\n", NR, col + 3; exit }
    }
  ' "$agents_md"
}

# Emit the mirror exclusions implied by the SOURCE manifest's
# doc_ownership inventory — every `class: hub-only` agent doc, one
# repo-relative path per line. Diagnostics go to stderr so stdout stays
# a clean path list.
#
# This is the single source of truth for "which agent docs never travel
# to a consumer". The class already carries that meaning; deriving it
# here is what makes BOOTSTRAP_MIRROR_EXCLUDES stop being a second copy
# of the same fact that an author had to keep in step by hand (#797
# review).
#
# The inventory is readable at bootstrap time because the manifest is
# read from the SOURCE root — mergepath's own worktree, which is what
# the wizard rsyncs FROM. The consumer's missing manifest is not a
# constraint here: the target has no manifest precisely because this
# stage has not populated it yet, and the exclusions are a property of
# the source. yq is likewise already a hard bootstrap dependency (the
# wizard's preflight step 1 requires it globally, and both
# bootstrap::_clean_repo_template_yml and
# bootstrap::_verify_canonical_agent_docs refuse to proceed without
# it), so this adds no new tool requirement — it uses the same
# derive-on-every-run posture _verify_canonical_agent_docs already
# applies to the canonical set.
#
# EVERY failure path returns non-zero, and the caller aborts the stage
# on it. A derivation that cannot be trusted must never degrade into
# "exclude nothing": that is the exact leak this replaces, except
# silent. An EMPTY result is a failure for the same reason — the live
# inventory always classifies some doc hub-only, so an empty set means
# the class name moved or the block was gutted, not that the set is
# genuinely empty.
#
# Derived paths are validated before they become rsync patterns. The
# inventory is scoped to Markdown under docs/agents/ (check 3a in
# scripts/ci/check_doc_ownership enforces exactly that), so anything
# else is a signal the scope changed and this derivation needs
# revisiting rather than a path to quietly hand to rsync. Wildcard
# metacharacters are rejected outright: rsync would honor them, and a
# single `docs/agents/*.md` entry would silently strip every canonical
# agent doc from the new repo.
bootstrap::_derive_hub_only_excludes() {
  local source_root=$1
  local manifest="$source_root/.mergepath-sync.yml"

  if [ ! -f "$manifest" ]; then
    bootstrap::err "source .mergepath-sync.yml missing at $manifest; cannot derive the hub-only mirror exclusions"
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    bootstrap::err "yq is required to derive the hub-only mirror exclusions from .mergepath-sync.yml. Install via 'brew install yq' (mikefarah/yq, v4+)."
    return 2
  fi
  if ! yq -e '.doc_ownership | tag == "!!seq"' "$manifest" >/dev/null 2>&1; then
    bootstrap::err "source .mergepath-sync.yml has no valid doc_ownership list; cannot derive the hub-only mirror exclusions"
    return 1
  fi

  local hub_only
  if ! hub_only=$(yq -r '.doc_ownership[] | select(.class == "hub-only") | .path' "$manifest" 2>&1); then
    bootstrap::err "could not derive hub-only docs from source .mergepath-sync.yml: $hub_only"
    return 1
  fi
  if [ -z "$hub_only" ]; then
    bootstrap::err "source .mergepath-sync.yml declares no 'class: hub-only' doc — refusing to mirror with an empty hub-only exclusion set, because that would copy hub-only content into the new repo. Check the doc_ownership inventory."
    return 1
  fi

  # Validate every entry BEFORE emitting any of it. Streaming each path
  # as it is checked would leave the already-validated prefix on stdout
  # when a later entry is rejected, and a caller that read stdout
  # without also testing the exit status would then mirror with a
  # PARTIAL exclusion set — the same silent-leak shape this function
  # exists to remove. Buffer, then print once the whole list is known
  # good.
  local doc raw_doc stripped validated=""
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    raw_doc="$doc"

    # Keep path acceptance aligned with check_doc_ownership: reject
    # unsafe segments first, then normalize harmless leading './'
    # spellings and a trailing slash before applying the inventory
    # scope check or emitting an rsync pattern.
    stripped="$doc"
    while [ "${stripped#./}" != "$stripped" ]; do stripped="${stripped#./}"; done
    case "$doc" in
      /*|..|../*|*/..|*/../*)
        bootstrap::err "hub-only doc path '$raw_doc' contains an absolute or '..' segment; refusing to build an rsync exclude pattern from it"
        return 1
        ;;
    esac
    case "$stripped" in
      *,*|*//*|*/.|*/./*)
        bootstrap::err "hub-only doc path '$raw_doc' contains an empty, '.', or comma-delimited segment; refusing to build an rsync exclude pattern from it"
        return 1
        ;;
    esac
    doc="${stripped%/}"
    case "$doc" in
      docs/agents/*.md) ;;
      *)
        bootstrap::err "doc_ownership classifies '$raw_doc' hub-only, but the bootstrap mirror derives exclusions only for 'docs/agents/*.md' paths. Widen bootstrap::_derive_hub_only_excludes deliberately if the inventory's scope changed."
        return 1
        ;;
    esac
    case "$doc" in
      *'*'*|*'?'*|*'['*)
        bootstrap::err "hub-only doc path '$raw_doc' contains an rsync wildcard metacharacter; a pattern like 'docs/agents/*.md' would strip every canonical agent doc from the new repo. Spell the path literally in doc_ownership."
        return 1
        ;;
    esac
    validated="${validated}${doc}"$'\n'
  done <<< "$hub_only"

  printf '%s' "$validated"
}

# Refuse to remove receiver residue through a symlinked directory below the
# selected target root. The derived paths are already constrained to literal,
# normalized repo-relative paths; this final check makes sure `$target/$path`
# still names the target tree rather than an external directory reached through
# (for example) a resumed target's `docs/agents` symlink.
bootstrap::_reject_symlink_ancestors() {
  local target=$1
  local rel=$2
  local parent=${rel%/*}
  local current=$target
  local component

  if [ -L "$target" ]; then
    bootstrap::err "template-mirror: refusing to remove stale hub-only doc '$rel': target root '$target' is a symbolic link and escapes the selected target tree"
    return 1
  fi

  [ "$parent" != "$rel" ] || return 0
  while [ -n "$parent" ]; do
    case "$parent" in
      */*)
        component=${parent%%/*}
        parent=${parent#*/}
        ;;
      *)
        component=$parent
        parent=
        ;;
    esac
    current="$current/$component"
    if [ -L "$current" ]; then
      bootstrap::err "template-mirror: refusing to remove stale hub-only doc '$rel': symlink ancestor '$current' escapes the selected target tree"
      return 1
    fi
  done
}

# bootstrap::_path_matches_any <path> <pattern...> — true when <path>
# matches one of the given BOOTSTRAP_MIRROR_EXCLUDES-style patterns (a
# trailing `/` = directory prefix, a bare basename with no `/` = matches
# anywhere by basename, anything else = exact path). Factored out of
# bootstrap::_resolve_canonical_source_sha (#1112 round 10) so a rename
# record's two sides can each be checked against the same pattern set
# without duplicating the match logic.
#
# Codex P2 on #1112 round 13: the exact-path branch required full string
# equality, but rsync's own --exclude for a slash-containing, non-trailing-
# slash pattern is NOT anchored to the transfer root either (round 11
# confirmed this for bootstrap::_reconcile_excluded_residue) -- a NESTED
# occurrence (e.g. nested/scripts/sync-to-downstream.sh) is excluded from
# the mirror by rsync just as the top-level one is, but this matcher only
# recognized the top-level form, so the cleanliness check flagged an
# otherwise-canonical checkout as dirty over a path that could never reach
# the target anyway. Now accepts a path ending in "/<pattern>" too, mirroring
# the directory-prefix branch's existing top-level-OR-nested shape.
bootstrap::_path_matches_any() {
  local check_path=$1
  shift
  local check_base="${check_path##*/}"
  local check_pattern
  for check_pattern in "$@"; do
    case "$check_pattern" in
      */)
        case "$check_path" in
          "$check_pattern"* | *"/$check_pattern"*) return 0 ;;
        esac
        ;;
      */*)
        case "$check_path" in
          "$check_pattern" | */"$check_pattern") return 0 ;;
        esac
        ;;
      *)
        [ "$check_base" = "$check_pattern" ] && return 0
        ;;
    esac
  done
  return 1
}

# bootstrap::_reconcile_excluded_residue <target> — a resumed Stage B may
# already carry receiver-only content at a path BOOTSTRAP_MIRROR_EXCLUDES
# names (Codex P2 on #1112 round 10): rsync's --delete (round 9) does not
# touch a destination path matching an active --exclude, by rsync's own
# default, so residue at an excluded path (e.g. a stale packaging/leftover
# from a mirror run before that path was excluded) survives untouched and
# the later `git add -A` commits it while attribution still names a clean
# source HEAD. Remove it explicitly, skipping BOOTSTRAP_MIRROR_RECONCILE_PROTECTED
# -- target-local state that must persist across resumes regardless of what
# the exclude array says.
#
# Codex P2 on #1112 round 11: a slash-containing rsync --exclude pattern
# (directory-prefix OR exact-path) is NOT anchored to the transfer root --
# rsync matches it at ANY depth (confirmed against this host's rsync:
# --exclude='scripts/sync-to-downstream.sh' also excludes
# nested/scripts/sync-to-downstream.sh, and --exclude='packaging/' also
# excludes nested/packaging/). Checking only "$target/$pattern" therefore
# missed nested matches that --delete equally protects. Every pattern shape
# is now reconciled the same way, via `find`: a bare basename by -name (any
# depth, matching rsync's own slash-less semantics), a directory-prefix or
# exact-path pattern by -path "*/<pattern-without-trailing-slash>" (the `*`
# absorbs zero or more leading path segments, so it matches both a
# top-level and a nested occurrence in one predicate). `find` never
# descends into a symlinked directory without -L, so none of this can be
# tricked into deleting outside target through a symlink swap.
#
# Codex P1 on #1112 round 12: pruning only `.git` from traversal was not
# enough. Skipping a BOOTSTRAP_MIRROR_RECONCILE_PROTECTED entry's OWN
# reconciliation pass does not stop find from DESCENDING into it on every
# OTHER pattern's pass -- an active .claude/worktrees/ checkout (itself
# potentially a full clone carrying scripts/sync-to-downstream.sh or
# packaging/) had its nested matches deleted anyway, destroying uncommitted
# operator work. Every protected DIRECTORY entry is now pruned from every
# reconciliation traversal, not merely excused from having its own pattern
# reconciled.
#
# Takes the pattern list as arguments (rather than reading
# BOOTSTRAP_MIRROR_EXCLUDES directly) so bootstrap::_rsync_template can
# reuse the exact same nested-match-aware removal for the DERIVED hub-only
# doc list too (Codex P2 on #1112 round 12) -- those paths are excluded
# from the transfer dynamically, at mirror time, so they need the same
# treatment as the static array's entries, not a separate root-only `rm`.
#
# Codex P1 on #1112 round 13: -mindepth 1 is required. `find "$target" ...
# -path "*/packaging" ...` matches find's OWN STARTING NODE too when
# $target's path string itself ends in "/packaging" (e.g. an operator's
# default ~/GitHub/packaging as the bootstrap target for a repo literally
# named packaging) -- reproduced: the whole target, including .git and
# resume state, was recursively removed. -mindepth 1 excludes depth 0 (the
# starting argument) from ever being a candidate, without affecting any
# genuine descendant match at depth 1+.
# Codex P2 on #1112 round 13: a bare (no `/`) protected entry like
# .bootstrap-state matches rsync's own --exclude at ANY depth by basename,
# same as any other bare pattern -- but the wizard's bookkeeping only ever
# lives at the target ROOT (scripts/bootstrap-new-repo.sh always writes
# "$TARGET_DIR/.bootstrap-state"), so blanket-skipping the whole pattern
# from reconciliation also protected a coincidentally-named NESTED file
# that is not wizard state at all, letting it survive under a falsely
# attributed source SHA.
#
# Codex P2 on #1112 round 14: the SAME class of bug applied to protected
# DIRECTORY entries too. `.git/` (and `.claude/worktrees/`) is anywhere-
# matching (`-path "*/.git"`), so a resumed target's receiver-only NESTED
# repo (e.g. stale/.git, left by some earlier interrupted operation) was
# ALSO pruned from every traversal as if it were the target's own repo --
# git then treats `stale/` as a gitlink (mode 160000) on `git add -A`,
# committing that residue under the source SHA. prune_expr is now
# root-anchored ($target/<dir>, not */<dir>): the root occurrence is still
# excluded automatically (prune claims it before the -o branch is ever
# reached for that exact node), but a nested occurrence of the same
# basename now falls through to ordinary reconciliation like any other
# pattern. This also lets every protected entry -- directory or file --
# share the SAME root_only_protect mechanism below, since a directory's
# own reconciliation pass never needs it to fire (prune already excludes
# the root node before -o is evaluated) but the two mechanisms agreeing is
# what makes them safe to unify rather than special-cased.
bootstrap::_reconcile_excluded_residue() {
  local target=$1
  shift
  local pattern protected root_only_protect match_arg

  # Codex P1 on #1112 round 18: `find -path` always does GLOB matching, not
  # literal string comparison -- a target containing a glob metacharacter
  # (`[`, `]`, `*`, `?`, e.g. an operator's own `/tmp/target[1]`) is
  # embedded verbatim into every -path pattern built from it below, so it
  # is interpreted as a PATTERN rather than the literal target path.
  # Reproduced: `find "target[1]" -path "target[1]/.git"` matches nothing,
  # because `[1]` is a character class, not literal brackets -- silently
  # defeating root_only_protect and prune_expr for such a target. Escape
  # find's own glob metacharacters in $target ONCE here, and use the
  # escaped form everywhere $target feeds into a -path pattern; find's
  # OWN starting-point argument (the unescaped "$target") is unaffected,
  # since that argument is a literal path, never a pattern.
  local target_escaped=$target
  target_escaped=${target_escaped//\\/\\\\}
  target_escaped=${target_escaped//\*/\\*}
  target_escaped=${target_escaped//\?/\\?}
  target_escaped=${target_escaped//\[/\\[}

  local prune_expr=()
  for protected in "${BOOTSTRAP_MIRROR_RECONCILE_PROTECTED[@]}"; do
    case "$protected" in
      */)
        [ "${#prune_expr[@]}" -eq 0 ] || prune_expr+=(-o)
        prune_expr+=(-path "$target_escaped/${protected%/}")
        ;;
    esac
  done

  for pattern in "$@"; do
    root_only_protect=""
    for protected in "${BOOTSTRAP_MIRROR_RECONCILE_PROTECTED[@]}"; do
      if [ "$pattern" = "$protected" ]; then
        root_only_protect="$target_escaped/${protected%/}"
        break
      fi
    done

    case "$pattern" in
      */) match_arg="*/${pattern%/}" ;;
      */*) match_arg="*/$pattern" ;;
      *) match_arg="" ;;
    esac

    if [ -n "$match_arg" ]; then
      if [ -n "$root_only_protect" ]; then
        bootstrap::run "reconcile excluded residue $pattern" \
          find "$target" -mindepth 1 \( "${prune_expr[@]}" \) -prune -o -path "$match_arg" ! -path "$root_only_protect" -exec rm -rf -- {} + \
          || return $?
      else
        bootstrap::run "reconcile excluded residue $pattern" \
          find "$target" -mindepth 1 \( "${prune_expr[@]}" \) -prune -o -path "$match_arg" -exec rm -rf -- {} + \
          || return $?
      fi
    else
      if [ -n "$root_only_protect" ]; then
        bootstrap::run "reconcile excluded residue $pattern" \
          find "$target" -mindepth 1 \( "${prune_expr[@]}" \) -prune -o -name "$pattern" ! -path "$root_only_protect" -exec rm -rf -- {} + \
          || return $?
      else
        bootstrap::run "reconcile excluded residue $pattern" \
          find "$target" -mindepth 1 \( "${prune_expr[@]}" \) -prune -o -name "$pattern" -exec rm -rf -- {} + \
          || return $?
      fi
    fi
  done
}

bootstrap::_rsync_template() {
  local source_root=$1
  local target=$2

  # Codex P1 on #1112 round 15: normalize away a trailing slash on $target
  # BEFORE any string-based path construction or comparison below. Every
  # root-anchored protection this function relies on -- the symlinked-
  # target-root guard just below, bootstrap::_reject_symlink_ancestors
  # further down, and bootstrap::_reconcile_excluded_residue's prune_expr
  # and root_only_protect (rounds 13-14) -- is built by string-concatenating
  # "$target/<suffix>". If the caller passed a target ending in "/" (a
  # common CLI convention), that concatenation produces a DOUBLE slash
  # ("$target//.git") that matches neither find's single-slash-normalized
  # output nor [ -L ]'s own path handling -- reproduced: [ -L "path/" ]
  # fails to detect a symlink at all, and every root_only_protect exclusion
  # silently stops matching, defeating both the symlink guard and the
  # root/.git, root/.bootstrap-state, root/.claude/worktrees protections in
  # one stroke.
  #
  # Codex P1 on #1112 round 16: a single strip is NOT sufficient --
  # `--target-dir /tmp/repo//` (two trailing separators) leaves one behind
  # after one `${target%/}` pass, reproducing the identical bug. Loop until
  # no trailing slash remains, so any number of trailing separators is
  # normalized away, not just exactly one.
  while [ "${target%/}" != "$target" ]; do
    target="${target%/}"
  done

  # CodeRabbit on #1112 round 16: a target of "/" (or "//", "///", ...)
  # normalizes to the EMPTY STRING by the loop above. `mkdir -p ""` fails
  # but isn't checked, and `[ -L "" ]` is false -- bootstrap::_reconcile_excluded_residue's
  # own `find "" ...` failure (caught by its `|| return $?` call below)
  # happens to already stop this before the final `rsync -a --delete
  # "$source_root/" "$target/"` (which would become `... "/"`, mirroring
  # over the filesystem root) is ever reached, but that is an accidental
  # side effect of find's own behavior on an empty path, not an explicit
  # invariant of this function. Refuse outright, with an actionable error
  # message, before anything else runs.
  if [ -z "$target" ]; then
    bootstrap::err "template-mirror: refusing to rsync into the filesystem root (target normalized to an empty path)"
    return 1
  fi

  # Codex P1 on #1112 round 9: --delete, not a bare mirror. A --resume
  # re-enters this stage from the top against a target that may already
  # carry a prior attempt's output — a path present then but removed from
  # source since, or any file rsync alone would never touch because it
  # only ever ADDS/UPDATES. Without --delete that residue survives into
  # the `git add -A` commit while _resolve_canonical_source_sha still
  # attributes the CURRENT source HEAD, so the recorded Source: trailer
  # would name a tree the target's actual bytes don't match. --delete
  # reconciles the target to exactly what a fresh mirror of source_root
  # would produce; it does not touch excluded destination paths (.git/,
  # hub-only docs, ...) by rsync's own default, so it cannot undo the
  # explicit hub-only-doc removal a few lines below or delete .git.
  local rsync_args=(-a --delete)
  local exc
  for exc in "${BOOTSTRAP_MIRROR_EXCLUDES[@]}"; do
    rsync_args+=(--exclude="$exc")
  done

  # Append the exclusions derived from the source manifest's ownership
  # inventory. Assigned in a separate statement from the `local`
  # declaration so the command substitution's exit status is the one
  # tested — `local x=$(...)` would return the declaration's status and
  # swallow a failed derivation, mirroring with no hub-only excludes at
  # all.
  local derived derive_rc=0
  derived=$(bootstrap::_derive_hub_only_excludes "$source_root") || derive_rc=$?
  if [ "$derive_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: refusing to rsync without the hub-only exclusions derived from .mergepath-sync.yml (rc=$derive_rc) — proceeding would copy hub-only docs into the new repo"
    return "$derive_rc"
  fi
  while IFS= read -r exc; do
    [ -n "$exc" ] || continue
    rsync_args+=(--exclude="$exc")
  done <<< "$derived"

  mkdir -p "$target"

  # Codex P1 on #1112 round 14: an explicit, unconditional guard, checked
  # BEFORE any destructive operation below -- not relying on the derived
  # hub-only-doc loop's bootstrap::_reject_symlink_ancestors call further
  # down to catch this as a side effect of iterating a non-empty $derived
  # list. If $target is itself a symlink to a populated directory, `mkdir
  # -p` on it is a no-op (the path "exists" via the link), and the FINAL
  # `rsync -a --delete ... "$target/"` below follows a trailing-slash
  # symlink destination just like a real directory -- reproduced: a
  # pre-existing file in the referent directory was deleted by --delete.
  if [ -L "$target" ]; then
    bootstrap::err "template-mirror: refusing to rsync into '$target': target root is a symbolic link and escapes the selected target tree"
    return 1
  fi

  bootstrap::_reconcile_excluded_residue "$target" "${BOOTSTRAP_MIRROR_EXCLUDES[@]}" || return $?

  # Exclusion prevents a new transfer but does not delete receiver residue.
  # A resumed Stage B may already carry a doc copied before its ownership was
  # changed to hub-only, so remove every validated derived path explicitly
  # at its root-relative location (this exact-path, symlink-ancestor-guarded
  # removal is what makes a failure here propagate rather than continue to
  # an excluding rsync that would then run against a still-populated,
  # partially-writable target).
  local derived_docs=()
  while IFS= read -r exc; do
    [ -n "$exc" ] || continue
    derived_docs+=("$exc")
    bootstrap::_reject_symlink_ancestors "$target" "$exc" || return $?
    bootstrap::run "remove stale hub-only doc $exc" rm -f -- "$target/$exc" \
      || return $?
  done <<< "$derived"

  # Codex P2 on #1112 round 12: the removal above is root-relative only,
  # and the derived exclusion matches at any depth in rsync's own filter
  # (same as the static array, round 11) -- reconcile nested occurrences
  # too. Safe to run unconditionally after the root-level pass above: a
  # path already removed there simply matches nothing here.
  if [ "${#derived_docs[@]}" -gt 0 ]; then
    bootstrap::_reconcile_excluded_residue "$target" "${derived_docs[@]}" || return $?
  fi

  bootstrap::run "rsync $source_root -> $target" \
    rsync "${rsync_args[@]}" "$source_root/" "$target/"
}

bootstrap::_remove_orphans() {
  local target=$1
  local rc=0

  # Codex P1 on #1112 round 17: bootstrap::_rsync_template normalizes a
  # trailing-slash target on its OWN local copy (rounds 15-16); that never
  # propagates back to the caller, and bootstrap::stage_template_mirror
  # passes the SAME unnormalized $target to this function separately. The
  # nested-match reconciliation this function calls into (round 16) builds
  # the identical doubled-slash root_only_protect/prune_expr paths a
  # trailing-slash target already broke there -- so a target ending in "/"
  # defeats THIS function's root protections too, descending into
  # .claude/worktrees/ or .git/ and deleting nested orphans. Normalize
  # here as well, rather than relying on the caller (or _rsync_template's
  # separate, non-propagating normalization) to have already done it.
  while [ "${target%/}" != "$target" ]; do
    target="${target%/}"
  done

  local orphan
  for orphan in "${BOOTSTRAP_POST_MIRROR_REMOVE[@]}"; do
    # -L catches a dangling symlink (-e is false for those), so a stale
    # symlinked CONTEXT.md on a resumed target is still removed.
    if [ -e "$target/$orphan" ] || [ -L "$target/$orphan" ]; then
      bootstrap::run "rm orphan $orphan" rm -f "$target/$orphan" || rc=$?
      # A survivor is a failure even if rm exited 0 (e.g. permission-masked):
      # Stage B must not continue with hub-only content still in the target.
      if [ -e "$target/$orphan" ] || [ -L "$target/$orphan" ]; then
        bootstrap::err "post-mirror removal left $orphan in the target"
        rc=1
      fi
    fi
  done

  # Codex P2 on #1112 round 16: the loop above is root-relative only, but
  # BOOTSTRAP_POST_MIRROR_REMOVE entries are ALSO in combined_excludes for
  # the cleanliness check (bootstrap::_resolve_canonical_source_sha), which
  # since round 13 matches an exact-path pattern at any depth -- a dirty
  # NESTED occurrence (e.g. nested/tests/test_mergepath_playground.sh) is
  # excused there on the assumption that no BOOTSTRAP_POST_MIRROR_REMOVE
  # entry ever reaches the target's committed tree, but rsync (no --exclude
  # names these) copies it and this loop never looked past the root. Reuse
  # the same nested-match-aware removal the excluded-residue path already
  # has, layered after the root-level pass above so its stricter failure
  # semantics (a survivor is a failure even when `rm` itself exits 0) are
  # unchanged for the common case.
  bootstrap::_reconcile_excluded_residue "$target" "${BOOTSTRAP_POST_MIRROR_REMOVE[@]}" || rc=$?

  local empty_dir
  for empty_dir in "${BOOTSTRAP_POST_MIRROR_RMDIR_IF_EMPTY[@]}"; do
    local dir_path="$target/$empty_dir"
    if [ -d "$dir_path" ] && [ -z "$(ls -A "$dir_path" 2>/dev/null)" ]; then
      bootstrap::run "rmdir empty $empty_dir" rmdir "$dir_path" || rc=$?
    fi
  done

  return "$rc"
}

bootstrap::_clean_repo_template_yml() {
  local target=$1
  local rtc="$target/.repo-template.yml"

  if [ ! -f "$rtc" ]; then
    # Absent file is a legitimate skip — the source mergepath may not
    # have a .repo-template.yml in some fixture scenarios. There's
    # nothing to clean up.
    bootstrap::log "no .repo-template.yml to clean up at $rtc"
    return 0
  fi

  # yq is REQUIRED here, not optional. Codex round 3 P1 on #233 caught
  # the original soft-skip-with-warning: if yq was unavailable the
  # stage returned 0 + recorded completion despite NOT cleaning the
  # playground spec_test_map. The subsequent substitution step would
  # then rename `mergepath_playground` → `<new-repo>_playground`,
  # baking stale template metadata into the new repo permanently.
  #
  # The wizard's preflight step 1 now requires yq globally — but we
  # keep this defense-in-depth check so a regression in preflight or
  # a stage invoked outside the wizard (e.g., a future re-use as a
  # standalone library) still fails closed.
  if ! command -v yq >/dev/null 2>&1; then
    bootstrap::err "yq is required for .repo-template.yml cleanup but is not on PATH. Install via 'brew install yq' (mikefarah/yq, v4+). Refusing to record stage completion with stale playground metadata."
    return 2
  fi

  bootstrap::run "drop mergepath-specific .repo-template.yml entries" \
    bootstrap::_yq_clean_repo_template "$rtc"
}

bootstrap::_yq_clean_repo_template() {
  local f=$1
  # Drop the playground spec_test_map entry (whose key is
  # "mergepath_playground" pre-substitution; substitution would
  # have renamed it to e.g. "newrepo_playground" — drop either form
  # by removing any entry whose value list contains the playground
  # test path).
  yq -i 'del(.spec_test_map.mergepath_playground)' "$f"
  # Drop the bootstrap consumer-identity spec_test_map entry (#747):
  # the spec AND its mapped hub-only test are both mirror-excluded, so
  # a surviving map entry is stale hub metadata in the consumer (and
  # this key is not name-bearing, so it survives substitution as-is).
  yq -i 'del(.spec_test_map.bootstrap_consumer_identity)' "$f"
  # Same rationale for the source-SHA-attribution spec (#1056, Codex P2
  # round 4 on #1112): it too is mirror-excluded (both it and the doc
  # ownership) alongside the hub-only test it maps to.
  yq -i 'del(.spec_test_map.bootstrap_source_attribution)' "$f"
  # Drop extra_top_level_dirs entirely — the new repo has no
  # mergepath/ or packaging/ dirs.
  yq -i 'del(.extra_top_level_dirs)' "$f"
}

# bootstrap::_resolve_canonical_source_sha <source_root> — prints the HEAD
# sha, exit 0, ONLY when source_root is verifiably a checkout of canonical
# mergepath (nathanjohnpayne/mergepath) whose HEAD is reachable from that
# repo's own remote history; prints nothing and exits 1 otherwise. Canonical
# behavior contract: specs/bootstrap_source_attribution.md (#1056/#1112).
#
# Three independent checks, each closing a gap the previous round found:
#
#   1. source_root IS the git toplevel (Codex P1 round 1). `git -C
#      "$source_root" rev-parse HEAD` alone is not a valid "is this a git
#      repo" test — Git's own repository discovery walks UP from a non-git
#      source_root and happily resolves against an ENCLOSING checkout's
#      .git, so a plain non-git directory nested inside an unrelated repo
#      would silently record that ancestor's HEAD. Canonicalized via
#      `pwd -P` so a symlinked path still matches.
#   2. origin names canonical mergepath, by an EXACT host+path match, not a
#      substring/suffix glob (Codex P1 + P2 round 2/3). A clean checkout of
#      a fork, or BOOTSTRAP_MERGEPATH_ROOT pointed at any other repo, passes
#      check 1 just as validly as canonical mergepath does — and an
#      unanchored `*github.com/...` suffix match is satisfied by
#      `evilgithub.com/...` too. Enumerate the exact accepted remote forms
#      instead of pattern-matching a suffix.
#   3. HEAD is contained in a remote-tracking ref under refs/remotes/origin
#      (Codex P1 round 3). A clean, correctly-origined checkout can still
#      carry an unpushed local commit on `main`; checks 1+2 alone would
#      attribute a sha that the canonical remote (and therefore
#      `git ls-tree -r "$HUB_REF"` run elsewhere) has never heard of.
#   4. source_root's working tree is clean (Codex P2 round 4). Wizard
#      preflight only validates the checkout at $SCRIPT_DIR/.. is clean —
#      if BOOTSTRAP_MERGEPATH_ROOT points at a DIFFERENT canonical-origin
#      checkout that preflight never saw, checks 1-3 alone would still
#      accept it. Stage B's rsync mirrors that checkout's WORKING-TREE
#      bytes (tracked edits and untracked files alike, not the committed
#      tree), so a dirty source_root would attribute a HEAD whose tree
#      does not match what was actually mirrored.
#
# `for-each-ref --count=1` (not a bare `for-each-ref | grep -q .`) is
# deliberate: under this file's `set -o pipefail`, a `grep -q` that exits
# after its first match while for-each-ref is still writing sends git
# SIGPIPE, which pipefail then surfaces as a failure — turning a REAL
# match into a false negative once the ref list is large enough to
# overflow the pipe buffer before grep exits (Codex P2 round 4, reproduced
# at ~5000 refs). Limiting the producer to one match removes the race
# instead of racing grep against it.
bootstrap::_resolve_canonical_source_sha() {
  local source_root=${1:-}
  [ -n "$source_root" ] && [ -d "$source_root" ] || return 1

  local toplevel
  toplevel=$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$toplevel" ] || return 1
  [ "$(cd "$toplevel" && pwd -P)" = "$(cd "$source_root" && pwd -P)" ] || return 1

  local origin
  origin=$(git -C "$source_root" remote get-url origin 2>/dev/null) || return 1
  case "$origin" in
    https://github.com/nathanjohnpayne/mergepath | https://github.com/nathanjohnpayne/mergepath.git | \
    http://github.com/nathanjohnpayne/mergepath | http://github.com/nathanjohnpayne/mergepath.git | \
    git@github.com:nathanjohnpayne/mergepath | git@github.com:nathanjohnpayne/mergepath.git | \
    ssh://git@github.com/nathanjohnpayne/mergepath | ssh://git@github.com/nathanjohnpayne/mergepath.git) ;;
    *) return 1 ;;
  esac

  git -C "$source_root" for-each-ref --count=1 --format='%(refname)' --contains HEAD refs/remotes/origin \
    | grep -q . || return 1

  # Codex P2 round 5: capture the command's own exit status, not just its
  # output — the bare form below let a FAILED `git status` (permissions,
  # corruption) read as "empty output, therefore clean" and attribute a sha
  # anyway. A failed read must fall back same as everything else here.
  #
  # CodeRabbit round 5: --ignored, not the default porcelain. rsync mirrors
  # whatever is physically present in source_root regardless of .gitignore,
  # so a gitignored-but-present file (a build artifact, a stray .env) is
  # invisible to the bare form and would still get copied into the target
  # while HEAD (the attributed sha) carries no record of it.
  #
  # Codex P2 round 8: --ignored alone over-corrects. A path that
  # BOOTSTRAP_MIRROR_EXCLUDES already keeps out of the mirror (.DS_Store,
  # .claude/worktrees/, ...) can never reach the target regardless of its
  # git status, so treating its mere presence as "dirty" rejects attribution
  # on completely ordinary operator checkouts (every macOS Finder-visited
  # directory grows a stray .DS_Store) for no integrity benefit — the exact
  # gap #1 exists to prevent, pointed the other way. Filter status lines
  # against the SAME exclude list the mirror itself uses before judging
  # cleanliness, so only bytes that would ACTUALLY be copied count.
  #
  # CodeRabbit round 8: pin --untracked-files=all and --ignore-submodules=none
  # on the command line. status.showUntrackedFiles=no or
  # diff.ignoreSubmodules=all in the operator's ambient gitconfig would
  # otherwise suppress exactly the entries this check exists to catch, while
  # rsync still copies the bytes those settings hid from `git status`.
  #
  # Codex P2 on #1112 round 11: pin -c core.filemode=true too. With
  # core.filemode=false (common on macOS/exotic checkouts, or set
  # deliberately) git status does not report a mode-only change at all, so
  # flipping a tracked file executable leaves this check reading clean while
  # rsync -a still preserves the physical (now-755) mode into the target --
  # a mismatch against HEAD's recorded (644) mode that has nothing to do
  # with content.
  #
  # Codex P2 on #1112 round 18: pin -c core.autocrlf=false too. With
  # core.autocrlf=true, checkout converts a tracked LF blob to CRLF on
  # disk, and git status's OWN default comparison re-applies the SAME
  # conversion when comparing disk to blob, so it reads clean even though
  # rsync copies the CRLF bytes physically on disk -- a real content
  # mismatch against HEAD's LF blob. Confirmed empirically: -c
  # core.autocrlf=false forces the comparison to use the raw disk bytes,
  # correctly reporting the file as modified.
  local status_output
  status_output=$(git -c core.filemode=true -c core.autocrlf=false -C "$source_root" status --porcelain --ignored \
    --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
  if [ -n "$status_output" ]; then
    # Codex P2 on #1112 round 9: the static BOOTSTRAP_MIRROR_EXCLUDES array
    # is not the complete set of paths a mirror never lands in the target.
    # A dirty docs/agents/*.md hub-only doc (excluded dynamically via
    # bootstrap::_derive_hub_only_excludes, not this static array) or a
    # dirty tests/test_mergepath_playground.sh / CONTEXT.md (rsynced, then
    # deleted by bootstrap::_remove_orphans' BOOTSTRAP_POST_MIRROR_REMOVE
    # pass) can never survive into the target's committed tree either, so
    # judging cleanliness against the static array alone rejects
    # attribution on a checkout that is, for mirroring purposes, clean.
    # Failure to derive the hub-only set is NOT propagated as an error
    # here (unlike bootstrap::_rsync_template, which must refuse to mirror
    # rather than risk shipping hub-only content) -- an empty derived set
    # only makes this check MORE conservative, same as before this round.
    local derived_hub_only=""
    derived_hub_only=$(bootstrap::_derive_hub_only_excludes "$source_root" 2>/dev/null) || derived_hub_only=""
    # Codex P2 on #1112 round 11: BOOTSTRAP_MIRROR_CONTROL_FILES (currently
    # just .mergepath-sync.yml) must NEVER be added to combined_excludes --
    # its own content decides what bootstrap::_derive_hub_only_excludes
    # excludes, so a dirty copy changes the mirror's actual output even
    # though the file itself never reaches the target.
    local combined_excludes=() candidate is_control control
    for candidate in "${BOOTSTRAP_MIRROR_EXCLUDES[@]}" "${BOOTSTRAP_POST_MIRROR_REMOVE[@]}"; do
      is_control=false
      for control in "${BOOTSTRAP_MIRROR_CONTROL_FILES[@]}"; do
        [ "$candidate" = "$control" ] && is_control=true && break
      done
      [ "$is_control" = true ] || combined_excludes+=("$candidate")
    done
    local hub_doc
    while IFS= read -r hub_doc; do
      [ -n "$hub_doc" ] || continue
      combined_excludes+=("$hub_doc")
    done <<<"$derived_hub_only"

    # Codex P2 on #1112 round 10: a rename/copy record's porcelain line is
    # "XY old -> new" on ONE line, not a single path. Slicing off the 3-char
    # status prefix and taking "${path##*/}" for basename matching then
    # reduces the WHOLE "old -> new" string to new's basename -- so a
    # tracked rename whose destination basename happens to match a bare
    # exclude pattern (e.g. `README.md -> x/.DS_Store`) was excused
    # entirely, even though the source path (README.md, real tracked
    # content) is gone from the mirror and the destination is excluded from
    # it too: the content simply vanishes from the target while HEAD still
    # has it. Check the OLD and NEW sides independently on a rename/copy
    # record (status code contains R or C) and require BOTH excluded before
    # excusing the record; a non-rename line checks the same single path
    # twice, unchanged from before this round.
    local line code rest old_path new_path is_dirty=false
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      code="${line:0:2}"
      rest="${line:3}"
      case "$code" in
        *R*|*C*)
          old_path="${rest%% -> *}"
          new_path="${rest#* -> }"
          ;;
        *)
          old_path="$rest"
          new_path="$rest"
          ;;
      esac
      if bootstrap::_path_matches_any "$old_path" "${combined_excludes[@]}" \
        && bootstrap::_path_matches_any "$new_path" "${combined_excludes[@]}"; then
        :
      else
        is_dirty=true
      fi
    done <<<"$status_output"
    [ "$is_dirty" = false ] || return 1
  fi

  git -C "$source_root" rev-parse HEAD 2>/dev/null
}

bootstrap::_init_target_git() {
  local target=$1
  local source_root=${2:-}

  if [ -d "$target/.git" ]; then
    bootstrap::log "target already has .git, skipping init"
    return 0
  fi

  bootstrap::run "git init $target" \
    git -C "$target" init -q -b main

  bootstrap::run "stage initial files" \
    git -C "$target" add -A

  # #1056: name the mergepath tree this consumer was mirrored from, so a
  # bootstrapped repo (which has no sync PR, and therefore none of the
  # Source:/branch-name provenance scripts/sync-to-downstream.sh writes on
  # every sync PR) still leaves a recoverable HUB_REF for the drift
  # measurement in docs/agents/propagation-ordering.md § Measuring tier
  # membership. Best-effort: an unreadable or non-canonical source_root
  # falls back to the un-attributed subject rather than blocking the
  # bootstrap over a diagnostic — see
  # bootstrap::_resolve_canonical_source_sha for what "canonical" requires.
  local source_sha=""
  source_sha=$(bootstrap::_resolve_canonical_source_sha "$source_root") || source_sha=""

  local commit_message
  if [ -n "$source_sha" ]; then
    # Subject carries the short sha (greppable, survives a squash); the
    # trailer carries the full sha as a clickable URL, matching the
    # Source: convention scripts/sync-to-downstream.sh already writes.
    commit_message="Initial commit (bootstrapped from mergepath@${source_sha:0:7})

Source: https://github.com/nathanjohnpayne/mergepath/commit/${source_sha}"
  else
    commit_message="Initial commit (bootstrapped from mergepath)"
  fi

  # Use the operator's git config for the commit identity. Tests
  # can override via BOOTSTRAP_AUTHOR_NAME / BOOTSTRAP_AUTHOR_EMAIL
  # to avoid depending on the developer's global git config.
  local author_name="${BOOTSTRAP_AUTHOR_NAME:-}"
  local author_email="${BOOTSTRAP_AUTHOR_EMAIL:-}"

  if [ -n "$author_name" ] && [ -n "$author_email" ]; then
    bootstrap::run "initial commit (with explicit identity)" \
      git -C "$target" \
        -c "user.name=$author_name" \
        -c "user.email=$author_email" \
        -c commit.gpgsign=false \
        commit -q -m "$commit_message"
  else
    bootstrap::run "initial commit" \
      git -C "$target" \
        -c commit.gpgsign=false \
        commit -q -m "$commit_message"
  fi
}

# --- cross-repo loop update -------------------------------------------------
#
# Writes to MERGEPATH itself (not the target). Opens a new branch on
# mergepath's worktree, appends the new repo to the loop docs, commits,
# pushes, and opens a PR. Heavily gated:
#
# - Preflight 6 (in the wizard) requires mergepath to be on main +
#   clean before any stage runs. This step trusts that invariant.
# - We refuse to operate on a worktree that isn't clean RIGHT NOW
#   (defensive — re-check in case an earlier stage dirtied it).
# - We prompt for explicit confirmation before pushing + opening the
#   PR. BOOTSTRAP_AUTO_CONFIRM=1 skips the prompt (for tests).
# - Dry-run path emits the plan without touching the worktree.
#
bootstrap::_cross_repo_loop_update() {
  local source_root=$1
  local repo_name
  repo_name=$(bootstrap_input repo_name)

  if [ "${BOOTSTRAP_SKIP_CROSS_REPO_LOOP:-0}" = "1" ]; then
    bootstrap::log "cross-repo loop update skipped (BOOTSTRAP_SKIP_CROSS_REPO_LOOP=1)"
    return 0
  fi

  # Confirm with the operator.
  if [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" != "1" ]; then
    echo
    echo "About to open a PR on mergepath itself to add '$repo_name' to the"
    echo "cross-repo loops in DEPLOYMENT.md and REVIEW_POLICY.md."
    echo "  source: $source_root"
    local reply
    read -r -p "Proceed? [y/N]: " reply
    case "${reply:-}" in
      y|Y|yes|YES) ;;
      *)
        bootstrap::log "cross-repo loop update declined by operator; skipping"
        return 0
        ;;
    esac
  fi

  # Re-verify mergepath state — defense-in-depth re-run of the
  # preflight check 6 in scripts/bootstrap-new-repo.sh. Honors the
  # same skip env var so tests / dev-loop runs that bypass preflight
  # don't trip here either.
  if [ "${BOOTSTRAP_SKIP_MERGEPATH_GUARD:-0}" != "1" ]; then
    local branch
    branch=$(git -C "$source_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$branch" != "main" ]; then
      bootstrap::err "cross-repo loop update: mergepath is on '$branch', expected 'main'; refusing"
      return 1
    fi
    if [ -n "$(git -C "$source_root" status --porcelain 2>/dev/null)" ]; then
      bootstrap::err "cross-repo loop update: mergepath worktree dirty; refusing to open PR"
      return 1
    fi
  fi

  # Probe for anchors BEFORE creating the branch. If neither doc has
  # the anchor, the cross-repo loop update can't safely insert and we
  # don't want to leave a stray empty branch on mergepath. The
  # anchors get introduced by a separate doc-refactor PR (see #204
  # implementation notes).
  local anchored_count=0
  if grep -q -F '<!-- bootstrap-loop-list-end -->' "$source_root/DEPLOYMENT.md" 2>/dev/null; then
    anchored_count=$((anchored_count + 1))
  fi
  if grep -q -F '<!-- bootstrap-loop-list-end -->' "$source_root/REVIEW_POLICY.md" 2>/dev/null; then
    anchored_count=$((anchored_count + 1))
  fi
  if [ "$anchored_count" -eq 0 ]; then
    bootstrap::warn "cross-repo loop update: neither DEPLOYMENT.md nor REVIEW_POLICY.md carries the '<!-- bootstrap-loop-list-end -->' anchor — manual action needed to add '$repo_name' to the loop lists. Skipping the PR."
    return 0
  fi

  local loop_branch="bootstrap/add-${repo_name}-to-loops"
  BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT=0

  # Per-step rc capture. The wizard's dispatch invokes this helper as
  # `bootstrap::_cross_repo_loop_update "$source_root" || step_rc=$?`,
  # which under bash disables `set -e` inside the called function. So
  # the file-top `set -euo pipefail` does NOT propagate failures from
  # the bootstrap::run calls below — each must be checked explicitly
  # or a mid-flight failure (e.g., push rejected, gh pr create denied)
  # can be masked by the success of a subsequent step (e.g., the
  # return-to-main checkout). Codex round 4 P1 on #233 caught this.
  local step_rc=0

  bootstrap::run "checkout $loop_branch on mergepath" \
    git -C "$source_root" checkout -q -b "$loop_branch" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: checkout failed (rc=$step_rc)"
    return "$step_rc"
  fi

  bootstrap::_append_repo_to_loop_doc "$source_root/DEPLOYMENT.md" "$repo_name" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: DEPLOYMENT.md anchor insert failed (rc=$step_rc)"
    # Best-effort recovery: return to main, delete the throwaway branch.
    # Failures here are noted but do not override the original failure.
    git -C "$source_root" checkout -q main 2>/dev/null || \
      bootstrap::warn "cross-repo loop update: recovery checkout main failed (worktree left on $loop_branch)"
    git -C "$source_root" branch -q -D "$loop_branch" 2>/dev/null || true
    return "$step_rc"
  fi
  bootstrap::_append_repo_to_loop_doc "$source_root/REVIEW_POLICY.md" "$repo_name" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: REVIEW_POLICY.md anchor insert failed (rc=$step_rc)"
    git -C "$source_root" checkout -q main 2>/dev/null || \
      bootstrap::warn "cross-repo loop update: recovery checkout main failed"
    git -C "$source_root" branch -q -D "$loop_branch" 2>/dev/null || true
    return "$step_rc"
  fi

  # If everything we touched ended up unmodified, abort the commit
  # entirely — no point in opening an empty PR. Switch back to main
  # and tombstone the throwaway branch. This is a soft no-op exit
  # (return 0), not a failure — the anchored_count probe at the top
  # said at least one doc had the anchor; this branch covers the
  # narrow case where it WAS there but `_append_repo_to_loop_doc`
  # later observed it had been removed mid-run.
  if [ "${BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT:-0}" -eq 2 ]; then
    bootstrap::warn "no loop docs were anchored at insert time — aborting cross-repo PR"
    bootstrap::run "return mergepath to main (no-op recovery)" \
      git -C "$source_root" checkout -q main || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::err "cross-repo loop update: recovery checkout failed (rc=$step_rc); worktree may be on $loop_branch"
      return "$step_rc"
    fi
    bootstrap::run "delete unused $loop_branch" \
      git -C "$source_root" branch -q -D "$loop_branch" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      # Best-effort — branch leftover is cosmetic, not blocking.
      bootstrap::warn "cross-repo loop update: branch deletion of $loop_branch failed (rc=$step_rc); manual cleanup needed"
      step_rc=0
    fi
    return 0
  fi

  bootstrap::run "stage loop-doc changes" \
    git -C "$source_root" add DEPLOYMENT.md REVIEW_POLICY.md || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: git add failed (rc=$step_rc)"
    return "$step_rc"
  fi

  bootstrap::run "commit loop-doc update" \
    git -C "$source_root" \
      -c commit.gpgsign=false \
      commit -q -m "docs: add $repo_name to cross-repo loops

Auto-generated by scripts/bootstrap/template-mirror.sh as part of
bootstrapping $repo_name from the Mergepath template (per #156).
" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: commit failed (rc=$step_rc)"
    return "$step_rc"
  fi

  bootstrap::run "push $loop_branch" \
    git -C "$source_root" push -u origin "$loop_branch" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: push failed (rc=$step_rc); $loop_branch left in place locally for manual recovery"
    return "$step_rc"
  fi

  # Open the PR under the AUTHOR identity (nathanjohnpayne), not the
  # reviewer identity. bootstrap::run_author_gh routes this through
  # scripts/gh-as-author.sh for live runs, so the token is verified
  # immediately before `gh pr create` and the wrapper performs its
  # post-create author check. No machine-global gh account is switched.
  local author_identity
  author_identity="$(bootstrap::author_identity)"
  local pr_create_rc=0
  bootstrap::run_author_gh "open PR for cross-repo loop update (as $author_identity)" \
    pr create --repo "${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}/mergepath" \
      --base main --head "$loop_branch" \
      --title "docs: add $repo_name to cross-repo loops" \
      --body "Auto-generated by \`scripts/bootstrap/template-mirror.sh\` while bootstrapping \`$repo_name\` from the Mergepath template (#156).

Adds \`$repo_name\` to the documented cross-repo loops in:
- DEPLOYMENT.md (bootstrap loop, return-to-main loop)
- REVIEW_POLICY.md (SSH-remote-switch loop)

Authoring-Agent: claude

## Self-Review
- Correctness: anchor-driven insertion; falls back to skip-with-warning if anchors missing.
- Regression risk: low; pure doc append above an existing anchor.
- Style: matches existing entries.
- Test coverage: scripts/ci/check_bootstrap_template_mirror covers the dry-run + no-anchor + author-token paths.
- Security: no new attack surface.
" || pr_create_rc=$?

  if [ "$pr_create_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: PR create failed (rc=$pr_create_rc)"
    return "$pr_create_rc"
  fi

  # Switch the local worktree back to main so the operator's
  # working tree is left tidy. This is independent of the gh keyring
  # state.
  bootstrap::run "return mergepath to main" \
    git -C "$source_root" checkout -q main || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "cross-repo loop update: post-PR checkout main failed (rc=$step_rc); worktree left on $loop_branch"
    return "$step_rc"
  fi
}

# Append the new repo to a loop doc. The doc carries an anchor string
# the wizard inserts above (so future bootstraps can deterministically
# find the right list). If the anchor is missing (older mergepath),
# the function appends an unanchored line at end-of-file with a
# warning so the operator can manually relocate it.
bootstrap::_append_repo_to_loop_doc() {
  local doc=$1
  local repo_name=$2
  # The anchor is a magic comment present in the doc once per loop
  # list. We append a new line right before the closing anchor. The
  # anchors are introduced in mergepath by a separate doc-refactor PR
  # that converts the bash-embedded repo lists into a structured list
  # (see #156 follow-up). Until that PR lands, anchors are absent and
  # this function logs a "manual action needed" message and returns
  # without modifying the doc — that's strictly safer than dropping a
  # line at end-of-file inside a bash snippet.
  local anchor='<!-- bootstrap-loop-list-end -->'

  if [ ! -f "$doc" ]; then
    bootstrap::warn "loop-doc not found, skipping: $doc"
    return 0
  fi

  if grep -q -F "$anchor" "$doc"; then
    bootstrap::run "insert $repo_name above anchor in $(basename "$doc")" \
      bootstrap::_anchor_insert "$doc" "$anchor" "- $repo_name"
  else
    bootstrap::warn "$(basename "$doc"): no '$anchor' anchor present; manual action needed to add '$repo_name' to the loop list. Skipping this doc."
    # Signal to the caller (via env var) that we did not modify this
    # doc, so the caller can decide whether to skip the commit step.
    BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT=$((${BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT:-0} + 1))
  fi
}

bootstrap::_anchor_insert() {
  local doc=$1 anchor=$2 line=$3
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-loop.XXXXXX")
  # Ensure the tmpfile is cleaned up on any error path — without
  # cleanup, a failed awk or mv left orphan files in $TMPDIR
  # (CodeRabbit caught this on #233 round 2). Do NOT use a
  # `trap ... RETURN` for it: bash does not scope a RETURN trap to
  # the function that set it, so it stays installed after this
  # function returns and re-fires when the CALLER (bootstrap::run)
  # returns — in a frame where $tmp is unbound — and under the
  # file-top `set -u` that aborts the whole wizard with
  # "tmp: unbound variable" (#733). Explicit `rm -f` on each exit
  # path preserves the orphan-cleanup guarantee without the leak
  # (same idiom as bootstrap::_print_summary in
  # board-and-summary.sh).
  # awk: when we hit the anchor line, emit $line first, then the anchor.
  if ! awk -v anchor="$anchor" -v line="$line" '
    $0 ~ anchor && !inserted { print line; inserted = 1 }
    { print }
  ' "$doc" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$doc"; then
    rm -f "$tmp"
    return 1
  fi
  # mv succeeded so $tmp no longer exists; nothing to clean up.
}
