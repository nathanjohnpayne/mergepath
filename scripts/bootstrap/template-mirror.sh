#!/usr/bin/env bash
# scripts/bootstrap/template-mirror.sh — bootstrap wizard stage B.
# Per #156 sub-B / #204.
#
# Responsibilities (in order):
#   1. rsync mergepath's worktree into the new repo's target dir,
#      honoring a curated exclude list that drops mergepath-only files
#      (the playground spec, packaging/, internal screenshots, etc.).
#   2. Remove post-rsync orphans the exclude list can't catch.
#   3. Apply name substitutions across the documented 6 name-bearing
#      files (via scripts/bootstrap/substitute.sh).
#   4. Drop mergepath-specific entries from the new repo's
#      .repo-template.yml (the playground spec_test_map + the
#      extra_top_level_dirs guard for mergepath/packaging).
#   5. Initialize the new repo's git history with a single
#      "Initial commit (bootstrapped from mergepath)" commit.
#
# The cross-repo loop update (open a Mergepath-side PR adding the
# new repo to the loop docs in DEPLOYMENT.md + REVIEW_POLICY.md) is
# the LAST step. It's gated on a separate confirmation prompt because
# it writes to mergepath itself, not to the target. Without
# BOOTSTRAP_AUTO_CONFIRM=1 the operator must say yes.
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

  # Screenshots — internal evidence, not template content
  'bugs/screenshots/'
  '.github/screenshots/'

  # State files from prior wizard runs (when re-running into the
  # same target dir)
  '.bootstrap-log'
  '.bootstrap-state'
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

  # Step 4: apply name substitutions across the 6 name-bearing files
  # (now that the playground key is gone from .repo-template.yml).
  bootstrap::apply_name_substitutions "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "template-mirror: substitution step failed (rc=$step_rc); aborting stage"
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
  mv "$policy.bootstrap-tmp" "$policy"
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
  # Ensure the tmpfile is cleaned up on any error path. Without the
  # trap, a failed awk or mv left orphan files in $TMPDIR.
  # CodeRabbit caught this on #233 round 2.
  trap 'rm -f "$tmp"' RETURN
  # awk: when we hit the anchor line, emit $line first, then the anchor.
  if ! awk -v anchor="$anchor" -v line="$line" '
    $0 ~ anchor && !inserted { print line; inserted = 1 }
    { print }
  ' "$doc" > "$tmp"; then
    return 1
  fi
  if ! mv "$tmp" "$doc"; then
    return 1
  fi
  # mv succeeded so $tmp no longer exists; the trap's rm -f is a
  # harmless no-op on the now-absent path.
}
