#!/usr/bin/env bash
# scripts/bootstrap/template-mirror.sh — bootstrap wizard stage B.
# Per #156 sub-B / #204.
#
# Responsibilities (in dispatch order — matches the numbered Step
# comments in bootstrap::stage_template_mirror):
#   1. rsync mergepath's worktree into the new repo's target dir,
#      honoring a curated exclude list that drops mergepath-only files
#      (the playground spec, packaging/, internal screenshots, the
#      hub-only machinery docs, and the pure-identity BRAND.md /
#      repository-overview.md, etc.).
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
#   7. Initialize the new repo's git history with a single
#      "Initial commit (bootstrapped from mergepath)" commit.
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
BOOTSTRAP_MIRROR_EXCLUDES=(
  # Repo metadata that should never propagate
  '.git/'
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

  # Hub identity docs — do NOT duplicate mergepath's self-referential
  # hub identity into a consumer (#744). Two groups:
  #
  #   * Hub-only MACHINERY docs describe processes a consumer does not
  #     run (the propagation wave, the bootstrap wizard, the templated-
  #     render engine — sync-to-downstream.sh / .mergepath-sync.yml
  #     aren't even present in a consumer, per the orchestrator excludes
  #     above). Copied verbatim they'd read as if the consumer were the
  #     hub. NB: ai_agent_tooling_standard.md is deliberately NOT here —
  #     it is the methodology-neutral Standard the consumer FOLLOWS (it
  #     correctly names mergepath as the reference implementation and is
  #     not name-substituted, so it stays true in a consumer), and
  #     README.md / .ai_context.md still link to it (Codex #746).
  #   * BRAND.md + docs/agents/repository-overview.md are 100% mergepath
  #     identity ("the reference implementation", the Playground/Cockpit/
  #     Tiebreaker/Checks surfaces). A lexical mergepath→<repo> swap
  #     leaves the self-referential claims intact and FALSE. These are
  #     excluded here and replaced by neutral consumer stubs in
  #     bootstrap::_scaffold_consumer_identity (step 5b below), so they
  #     are also dropped from BOOTSTRAP_NAME_BEARING_FILES in
  #     substitute.sh. (The mixed doc .ai_context.md keeps its shared
  #     content and is fixed at the mergepath source, not here; the
  #     AGENTS.md packaging note is scrubbed in step 5b.)
  'docs/agents/bootstrap-runbook.md'
  'docs/agents/propagation-ordering.md'
  'docs/agents/templated-propagation.md'
  'BRAND.md'
  'docs/agents/repository-overview.md'

  # Screenshots — internal evidence, not template content
  'bugs/screenshots/'
  '.github/screenshots/'

  # State files from prior wizard runs (when re-running into the
  # same target dir)
  '.bootstrap-log'
  '.bootstrap-state'
)

# Canonical agent docs a NEW repo must come out of bootstrap carrying
# (#780). These are `class: canonical` in .mergepath-sync.yml's
# doc_ownership inventory: one source of truth on the hub, mirrored
# verbatim, written to be true in every repo that receives them. The
# rsync above already copies them (they are not excluded), so this list
# is a POSITIVE assertion, not a delivery mechanism — it exists so a
# future exclude-pattern change cannot silently strip a shared rulebook
# out of every repo bootstrapped afterwards. The failure it guards
# against is invisible at bootstrap time and only shows up as an agent
# in a new repo that has never read the shared rules.
#
# Keep in sync with the `class: canonical` entries in the manifest's
# doc_ownership block.
BOOTSTRAP_REQUIRED_CANONICAL_AGENT_DOCS=(
  'docs/agents/shared-operating-rules.md'
  'docs/agents/worktree-placement.md'
)

# Files that rsync leaves behind because they don't match an exclude
# pattern but shouldn't ship to a new repo. Post-mirror cleanup.
BOOTSTRAP_POST_MIRROR_REMOVE=(
  tests/test_mergepath_playground.sh
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
  # mergepath identity) and the three hub-only docs; this writes honest
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
  bootstrap::_verify_canonical_agent_docs "$target" || step_rc=$?
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
  bootstrap::_init_target_git "$target" || step_rc=$?
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
# docs/agents/repository-overview.md (pure mergepath identity) and the
# three hub-only docs; this writes honest consumer stubs for the two
# excluded identity docs and removes the AGENTS.md "Repository Layout"
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
#   1. Every BOOTSTRAP_REQUIRED_CANONICAL_AGENT_DOCS file landed. The
#      rsync copies them by default, so a failure here means someone
#      added an exclude pattern that swallows a canonical doc.
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

  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::log "dry-run: would verify the canonical agent docs landed in $target and that AGENTS.md reads the shared operating rules before the local overlay"
    return 0
  fi

  local missing="" doc
  for doc in "${BOOTSTRAP_REQUIRED_CANONICAL_AGENT_DOCS[@]}"; do
    [ -f "$target/$doc" ] || missing="$missing $doc"
  done
  if [ -n "$missing" ]; then
    bootstrap::err "canonical agent docs missing from the mirrored repo:$missing — these are 'class: canonical' in .mergepath-sync.yml's doc_ownership inventory and every new repo must carry them. Check BOOTSTRAP_MIRROR_EXCLUDES for a pattern that swallows them."
    return 1
  fi

  local agents_md="$target/AGENTS.md"
  if [ ! -f "$agents_md" ]; then
    bootstrap::err "AGENTS.md missing from the mirrored repo; cannot verify the agent-docs reading order"
    return 1
  fi

  local shared_line local_line
  shared_line=$(grep -n -F -m1 'docs/agents/shared-operating-rules.md' "$agents_md" | cut -d: -f1 || true)
  local_line=$(grep -n -F -m1 'docs/agents/operating-rules.md' "$agents_md" | cut -d: -f1 || true)

  if [ -z "$shared_line" ]; then
    bootstrap::err "AGENTS.md does not reference docs/agents/shared-operating-rules.md — the new repo would ship the shared rulebook with nothing pointing at it. Add it to the AGENTS.md reading order at the mergepath source."
    return 1
  fi
  if [ -n "$local_line" ] && [ "$shared_line" -gt "$local_line" ]; then
    bootstrap::err "AGENTS.md lists docs/agents/operating-rules.md (line $local_line) BEFORE docs/agents/shared-operating-rules.md (line $shared_line) — the shared canonical rules must come first, with the per-repo overlay after. Fix the ordering at the mergepath source."
    return 1
  fi

  bootstrap::log "canonical agent docs present and AGENTS.md reads the shared operating rules before the local overlay"
  return 0
}

bootstrap::_rsync_template() {
  local source_root=$1
  local target=$2

  # Build the rsync arg list.
  local rsync_args=(-a)
  local exc
  for exc in "${BOOTSTRAP_MIRROR_EXCLUDES[@]}"; do
    rsync_args+=(--exclude="$exc")
  done

  mkdir -p "$target"

  bootstrap::run "rsync $source_root -> $target" \
    rsync "${rsync_args[@]}" "$source_root/" "$target/"
}

bootstrap::_remove_orphans() {
  local target=$1

  local orphan
  for orphan in "${BOOTSTRAP_POST_MIRROR_REMOVE[@]}"; do
    if [ -e "$target/$orphan" ]; then
      bootstrap::run "rm orphan $orphan" rm -f "$target/$orphan"
    fi
  done

  local empty_dir
  for empty_dir in "${BOOTSTRAP_POST_MIRROR_RMDIR_IF_EMPTY[@]}"; do
    local dir_path="$target/$empty_dir"
    if [ -d "$dir_path" ] && [ -z "$(ls -A "$dir_path" 2>/dev/null)" ]; then
      bootstrap::run "rmdir empty $empty_dir" rmdir "$dir_path"
    fi
  done
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
  # Drop extra_top_level_dirs entirely — the new repo has no
  # mergepath/ or packaging/ dirs.
  yq -i 'del(.extra_top_level_dirs)' "$f"
}

bootstrap::_init_target_git() {
  local target=$1

  if [ -d "$target/.git" ]; then
    bootstrap::log "target already has .git, skipping init"
    return 0
  fi

  bootstrap::run "git init $target" \
    git -C "$target" init -q -b main

  bootstrap::run "stage initial files" \
    git -C "$target" add -A

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
        commit -q -m "Initial commit (bootstrapped from mergepath)"
  else
    bootstrap::run "initial commit" \
      git -C "$target" \
        -c commit.gpgsign=false \
        commit -q -m "Initial commit (bootstrapped from mergepath)"
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
