#!/usr/bin/env bash
# scripts/bootstrap/board-and-summary.sh — bootstrap wizard stage E.
# Per #156 sub-E / #207.
#
# Responsibilities (in order):
#   1. Project v2 board: create a new board (or reuse an existing
#      project number) for the new repo. Skipped when
#      BOOTSTRAP_INPUT_PROJECT=skip OR BOOTSTRAP_SKIP_BOARD=1. The
#      summary block still runs in that case — the wizard's
#      "what's done / what's next" surface is too valuable to gate on
#      whether the operator wanted a board.
#   2. Empty PRD / spec / plan scaffold files in TARGET_DIR. These are
#      placeholders the human owns filling in (per #156's
#      "deliberately not in scope" decision).
#   3. Final summary block printed to stdout AND appended to
#      $TARGET_DIR/.bootstrap-log. Sections: REPO/PROJECT/LOCAL DIR
#      header, DONE, SKIPPED, WARNINGS, CROSS-REPO LOOP UPDATE,
#      NEXT STEPS. The summary is the operator's
#      discoverability surface — they can re-read .bootstrap-log
#      months later to remember what the wizard did.
#
# Reads (set by the wizard):
#   $TARGET_DIR                Local path of the new repo.
#   $BOOTSTRAP_REPO_OWNER      GitHub owner (default: nathanjohnpayne).
#   $BOOTSTRAP_LOG_FILE        Transcript log path (also doubles as the
#                              destination for the appended summary).
#   $BOOTSTRAP_STATE_FILE      State file used to decide DONE vs SKIPPED.
#   bootstrap_input project    "new" | "<N>" | "skip".
#   bootstrap_input repo_name  New repo name.
#   bootstrap_input description One-line repo description.
#
# Env overrides:
#   BOOTSTRAP_SKIP_BOARD=1            Skip sub-step 1 (project board);
#                                     summary + scaffolds still run.
#   BOOTSTRAP_SKIP_AUTHOR_TOKEN=1     tests only: run gh shim directly
#                                     instead of the token-verifying
#                                     author wrapper.
#   BOOTSTRAP_AUTHOR_IDENTITY         Override target identity for
#                                     author token verification (default
#                                     nathanjohnpayne).
#
# Side effects via bootstrap::run so --dry-run prints instead of executing.
# Project board calls are gh write paths and use the token-verifying
# author wrapper per command. Scaffold files are direct shell redirects,
# no auth wrapper needed.

set -euo pipefail

bootstrap::stage_board_and_summary() {
  bootstrap::stage_banner "board-and-summary"

  local repo_name owner full_repo target visibility project description
  repo_name=$(bootstrap_input repo_name)
  owner="${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}"
  full_repo="$owner/$repo_name"
  target=${TARGET_DIR:?TARGET_DIR not set by wizard}
  visibility=$(bootstrap_input visibility)
  project=$(bootstrap_input project)
  description=$(bootstrap_input description)

  # Per-step rc capture so the stage propagates failures cleanly
  # (matches sub-B / sub-C pattern: `set -e` inside a function called
  # as `fn || rc=$?` is disabled by bash, so we capture rc explicitly).
  local step_rc=0

  # Decide whether to run sub-step 1 (project board). Two paths both
  # skip it but still let the rest of the stage run:
  #   - BOOTSTRAP_SKIP_BOARD=1 (the --skip-board flag)
  #   - BOOTSTRAP_INPUT_PROJECT=skip (env-var control for tests)
  local skip_board=0
  if [ "${BOOTSTRAP_SKIP_BOARD:-0}" = "1" ] || [ "$project" = "skip" ]; then
    skip_board=1
  fi

  # GitHub writes in this stage are author-attributed per command via
  # bootstrap::run_author_gh / bootstrap::author_gh. No global auth
  # state is mutated, so existing failure paths can keep calling this
  # no-op helper without carrying restore state.
  bootstrap::_bs_restore_active_if_needed() {
    :
  }

  # Sub-step 1: project v2 board.
  local project_number=""
  local project_skipped_reason=""
  if [ "$skip_board" = "1" ]; then
    if [ "${BOOTSTRAP_SKIP_BOARD:-0}" = "1" ]; then
      project_skipped_reason="--skip-board"
    else
      project_skipped_reason="project=skip"
    fi
    bootstrap::log "project board skipped ($project_skipped_reason)"
  else
    bootstrap::_provision_project_board "$owner" "$repo_name" "$description" "$project" project_number || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::err "board-and-summary: project board provisioning failed (rc=$step_rc)"
      bootstrap::_bs_restore_active_if_needed
      return "$step_rc"
    fi
  fi

  # Sub-step 2: empty PRD/spec/plan scaffolds. Direct file writes — no
  # gh involved, so the auth wrap is irrelevant here. Still go through
  # bootstrap::run so --dry-run prints the plan.
  bootstrap::_write_placeholder_scaffolds "$target" "$repo_name" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "board-and-summary: scaffold creation failed (rc=$step_rc)"
    bootstrap::_bs_restore_active_if_needed
    return "$step_rc"
  fi

  # ----- end author-identity wrap -----
  bootstrap::_bs_restore_active_if_needed

  # Sub-step 3: final summary. Reads the state file to determine which
  # stages completed (DONE) vs which were skipped (SKIPPED). Prints to
  # stdout AND appends to $BOOTSTRAP_LOG_FILE.
  bootstrap::_print_summary \
    "$full_repo" "$target" "$visibility" \
    "$project_number" "$project_skipped_reason" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "board-and-summary: summary emission failed (rc=$step_rc)"
    return "$step_rc"
  fi

  bootstrap::record_stage "board-and-summary"
  return 0
}

# --- internal helpers ------------------------------------------------------

# Provision the Project v2 board: create a new one (and configure the
# Status field + readme) or attach to an existing project number.
#
# Args:
#   $1 owner       GitHub owner (e.g., nathanjohnpayne)
#   $2 repo_name   New repo name
#   $3 description One-line description used as the readme prefix
#   $4 project     "new" | "<N>" (digits)
#   $5 out_var     Name of caller variable to set with the project number
bootstrap::_provision_project_board() {
  local owner=$1 repo_name=$2 description=$3 project=$4 out_var=$5
  local pn=""

  case "$project" in
    new)
      # Create a new Project v2. Use --format json so the number is
      # parseable. We capture stdout via a tmpfile (cleaned up before
      # every return path; we deliberately don't use a RETURN trap
      # here — RETURN traps under `set -u` can fire with `tmp` unbound
      # if the function exits via set -e before `tmp=...` ran, and
      # propagating cleanup via explicit unset+rm is bash-3.2-safe).
      local _bs_tmp=""
      _bs_tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-project.XXXXXX")

      if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
        bootstrap::run_author_gh "create Project v2: $repo_name" \
          project create --owner "$owner" --title "$repo_name" --format json
        # Dry-run: invent a placeholder number so the rest of the stage
        # can print a plan without a real API response.
        pn="<N>"
        rm -f "$_bs_tmp"
      else
        # Live path: pipe gh's json output to the tmpfile then parse.
        bootstrap::log "creating Project v2: $repo_name"
        # `bootstrap::run` echoes the command line for the transcript;
        # we still capture stdout via process substitution to grab the
        # number. Use bootstrap::author_gh so the value-bearing live
        # command still verifies the author token without logging token
        # material.
        if [ -n "${BOOTSTRAP_LOG_FILE:-}" ]; then
          mkdir -p "$(dirname "$BOOTSTRAP_LOG_FILE")"
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) create Project v2: gh project create --owner $owner --title $repo_name --format json" \
            >>"$BOOTSTRAP_LOG_FILE"
        fi
        local create_rc=0
        bootstrap::author_gh project create --owner "$owner" --title "$repo_name" --format json >"$_bs_tmp" 2>&1 || create_rc=$?
        if [ "$create_rc" -ne 0 ]; then
          bootstrap::err "project create failed (rc=$create_rc): $(cat "$_bs_tmp")"
          rm -f "$_bs_tmp"
          return "$create_rc"
        fi
        # Parse `.number` via jq if available; fall back to a sed
        # extraction so the stage doesn't require jq on PATH (it's
        # not in the wizard's required-tool list).
        if command -v jq >/dev/null 2>&1; then
          pn=$(jq -r '.number' <"$_bs_tmp" 2>/dev/null || true)
        else
          pn=$(sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <"$_bs_tmp" | head -1)
        fi
        if [ -z "$pn" ]; then
          bootstrap::err "project create succeeded but could not parse project number from response: $(cat "$_bs_tmp")"
          rm -f "$_bs_tmp"
          return 2
        fi
        rm -f "$_bs_tmp"
        bootstrap::log "created Project v2 #$pn"
      fi

      # Configure the Status field (Backlog / Ready / In progress /
      # In review / Done). Idempotency-by-design isn't available on
      # gh project field-create; a re-run would error if Status already
      # exists. That's acceptable for now — the new-board path is
      # only meant to run once per repo.
      bootstrap::run_author_gh "Status field: Backlog/Ready/In progress/In review/Done" \
        project field-create "$pn" --owner "$owner" \
          --name Status --data-type SINGLE_SELECT \
          --single-select-options "Backlog,Ready,In progress,In review,Done" \
        || {
          # Field-create failure is warned-not-fatal: the board exists,
          # the operator can configure the field manually. Summary
          # surfaces the gap.
          bootstrap::warn "board-and-summary: Status field-create failed (project #$pn left without canonical Status field; configure manually if needed)"
        }

      # Set the board readme to a short stub pointing at the new repo's
      # description + a TODO marker. The operator overwrites this with
      # real PRD content later.
      local readme_body="$description

# Phase 0 — Foundations
TODO: populate from the new repo's PRD / spec.

Generated by scripts/bootstrap-new-repo.sh (#156 sub-E)."
      bootstrap::run_author_gh "set board readme" \
        project edit "$pn" --owner "$owner" --readme "$readme_body" \
        || {
          bootstrap::warn "board-and-summary: project edit --readme failed; configure manually if needed"
        }
      ;;
    skip)
      # Caller should have filtered this case before invoking; defensive.
      bootstrap::log "project board provisioning called with project=skip; no-op"
      ;;
    *)
      # Numeric: reuse the existing project. No create, no field-create,
      # no readme update — assume the operator already configured #N.
      pn="$project"
      bootstrap::log "reusing existing Project v2 #$pn (skipping create + field-create + readme)"
      ;;
  esac

  # Assign the project number to the caller's named output variable.
  # bash 3.2 lacks `declare -n`; use `printf -v` for the indirect set.
  printf -v "$out_var" '%s' "$pn"
}

# Write three placeholder scaffolds to the new repo:
#   - specs/$repo_name.md             (implementation-spec stub)
#   - plans/$repo_name-sprint-0.md    (Sprint 0 plan stub)
#   - scripts/gh-projects/examples/$repo_name/create-issues.sh
#                                     (issue-seeding script stub)
bootstrap::_write_placeholder_scaffolds() {
  local target=$1 repo_name=$2

  local spec_path="$target/specs/$repo_name.md"
  local plan_path="$target/plans/$repo_name-sprint-0.md"
  local examples_dir="$target/scripts/gh-projects/examples/$repo_name"
  local examples_path="$examples_dir/create-issues.sh"

  bootstrap::run "mkdir specs/" mkdir -p "$target/specs"
  bootstrap::run "mkdir plans/" mkdir -p "$target/plans"
  bootstrap::run "mkdir gh-projects/examples/$repo_name/" mkdir -p "$examples_dir"

  # The implementation-spec stub. Single-line content per #207's spec. We use a
  # heredoc through `tee` so bootstrap::run captures the side effect
  # cleanly (and so dry-run prints the command line).
  local spec_body="TODO: write the implementation spec for this repo. Canonical PRDs live in nathanjohnpayne/docs/projects/<project>/prds/ and are mirrored here via project-doc sync."
  bootstrap::run "write specs/$repo_name.md (placeholder)" \
    bootstrap::_write_file "$spec_path" "$spec_body"

  # Distinct placeholder from the spec stub above: an operator reading
  # both files can see at a glance which is "what behavior this repo
  # implements" (spec) vs "how we're rolling it out" (sprint plan / milestone
  # breakdown). CodeRabbit caught the identical-text nit on round 1.
  local plan_body="TODO: write the Sprint 0 plan (milestone breakdown / phasing) for this repo. Wizard left this empty per #156 deliberate-not-in-scope decision."
  bootstrap::run "write plans/$repo_name-sprint-0.md (placeholder)" \
    bootstrap::_write_file "$plan_path" "$plan_body"

  # create-issues.sh skeleton. Minimal 10-line stub matching the
  # gh-projects/examples/ convention in nathanpaynedotcom. The
  # operator fills in the actual issue list.
  local create_issues_body='#!/usr/bin/env bash
# scripts/gh-projects/examples/<repo>/create-issues.sh
#
# Phase 0 / Phase 1 issue-seeding skeleton for <repo>. Generated by
# the Mergepath bootstrap wizard (#156 sub-E). Fill in the issue list
# and run once after the repo is bootstrapped.
#
# Usage: bash scripts/gh-projects/examples/<repo>/create-issues.sh

set -euo pipefail

# TODO: populate with the Phase 0 / Phase 1 issues for <repo>.
# Example shape:
#   gh issue create --repo nathanjohnpayne/<repo> \
#     --title "Phase 0: scaffold" \
#     --label phase-0,agent-action \
#     --body "..."
'
  bootstrap::run "write scripts/gh-projects/examples/$repo_name/create-issues.sh (placeholder)" \
    bootstrap::_write_file "$examples_path" "$create_issues_body"
  bootstrap::run "chmod +x create-issues.sh" chmod +x "$examples_path" || true
}

# Internal: write $2 to file $1, creating parent dir as needed. Used by
# bootstrap::run so the dry-run path prints the call shape and the live
# path actually writes the file.
bootstrap::_write_file() {
  local path=$1 body=$2
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

# Print the end-of-run summary to stdout AND append to
# $BOOTSTRAP_LOG_FILE. Uses the state file at $BOOTSTRAP_STATE_FILE
# to decide which stages completed (DONE) vs which were skipped
# (SKIPPED).
bootstrap::_print_summary() {
  local full_repo=$1 target=$2 visibility=$3 project_number=$4 project_skipped_reason=$5

  local owner repo_name
  owner=${full_repo%%/*}
  repo_name=${full_repo#*/}

  # Build the summary in-memory then dump it to both stdout and the
  # log file. printf into a tmp buffer keeps the two destinations in
  # sync. We deliberately don't use a RETURN trap here — under `set -u`
  # a RETURN trap referencing a local var can fire with the var unbound
  # during the parent function's return chain (bash 3.2 quirk). Use
  # explicit rm -f at each exit instead.
  local _bs_summary_tmp=""
  _bs_summary_tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-summary.XXXXXX")

  {
    echo
    echo "==> Bootstrap complete: $full_repo"
    echo
    echo "REPO:        https://github.com/$full_repo"
    if [ -n "$project_number" ]; then
      # Project URLs differ by owner type: user-owned uses /users/<name>/
      # and org-owned uses /orgs/<name>/. Default to user-owned because
      # nathanjohnpayne (the documented BOOTSTRAP_REPO_OWNER) is a user
      # account, which is the only scope this script ships supporting
      # today. BOOTSTRAP_PROJECT_OWNER_TYPE=org overrides for callers
      # bootstrapping into an org-owned scope. CodeRabbit nitpick on
      # #246 round 2 called out the assumption — see the issue body for
      # the upgrade path if/when an org-owned bootstrap lands.
      case "${BOOTSTRAP_PROJECT_OWNER_TYPE:-user}" in
        org)  echo "PROJECT:     https://github.com/orgs/$owner/projects/$project_number" ;;
        *)    echo "PROJECT:     https://github.com/users/$owner/projects/$project_number" ;;
      esac
    elif [ -n "$project_skipped_reason" ]; then
      echo "PROJECT:     (skipped: $project_skipped_reason)"
    else
      echo "PROJECT:     (not configured)"
    fi
    echo "LOCAL DIR:   $target"
    echo
  } >>"$_bs_summary_tmp"

  # Determine DONE / SKIPPED from the state file. The state file
  # records every stage that completed (whether by running or via the
  # wizard's record-and-skip path). We don't have a separate "skipped"
  # marker, so we cross-reference against the known STAGES list:
  #   - In state file AND we know it ran → DONE
  #   - In state file but a stage-specific skip flag was set → SKIPPED
  #   - Not in state file → SKIPPED (incomplete run)
  local state_file="${BOOTSTRAP_STATE_FILE:-}"
  local stages="template-mirror github-infra firebase-and-codereview board-and-summary"
  local s done_lines="" skipped_lines=""
  for s in $stages; do
    local in_state=0
    if [ -n "$state_file" ] && [ -f "$state_file" ] \
         && grep -q "^${s}\$" "$state_file" 2>/dev/null; then
      in_state=1
    fi
    case "$s" in
      template-mirror)
        if [ "$in_state" = "1" ]; then
          done_lines="$done_lines  [done] Template mirror + name substitution
"
        else
          skipped_lines="$skipped_lines  [skip] Template mirror (not in state file)
"
        fi
        ;;
      github-infra)
        if [ "$in_state" = "1" ]; then
          done_lines="$done_lines  [done] GitHub repo created ($visibility) + 12 labels + reviewer invites + secrets
"
        else
          skipped_lines="$skipped_lines  [skip] GitHub repo + labels + invites + secrets (not in state file)
"
        fi
        ;;
      firebase-and-codereview)
        if [ "$in_state" = "1" ]; then
          local fb=${BOOTSTRAP_INPUT_FIREBASE:-none}
          if [ "$fb" = "none" ]; then
            skipped_lines="$skipped_lines  [skip] Firebase setup (firebase=none)
"
            done_lines="$done_lines  [done] CodeRabbit + Codex App posture
"
          else
            done_lines="$done_lines  [done] Firebase ($fb) + CodeRabbit + Codex App posture
"
          fi
        else
          skipped_lines="$skipped_lines  [skip] Firebase + CodeRabbit + Codex posture (not in state file)
"
        fi
        ;;
      board-and-summary)
        # The current stage. Project sub-step may have been skipped;
        # the summary itself is always run.
        if [ -n "$project_number" ]; then
          done_lines="$done_lines  [done] Project v2 board configured (#$project_number)
"
        else
          if [ -n "$project_skipped_reason" ]; then
            skipped_lines="$skipped_lines  [skip] Project v2 board ($project_skipped_reason)
"
          else
            skipped_lines="$skipped_lines  [skip] Project v2 board (not configured)
"
          fi
        fi
        done_lines="$done_lines  [done] Empty implementation-spec / plan scaffolds written
"
        ;;
    esac
  done

  {
    echo "DONE:"
    # Strip trailing newline from `printf %s` to avoid a blank line.
    printf '%s' "$done_lines"
    echo
    echo "SKIPPED:"
    if [ -n "$skipped_lines" ]; then
      printf '%s' "$skipped_lines"
    else
      echo "  (none)"
    fi
    echo
    echo "WARNINGS:"
    echo "  - Population of .env.local from Firebase web console is manual."
    echo "  - Reviewer-identity collaborator invites must be accepted by each"
    echo "    agent account at https://github.com/$full_repo/invitations."
    echo
    echo "CROSS-REPO LOOP UPDATE:"
    echo "  See template-mirror stage output above for the PR (if anchors"
    echo "  were present). If anchors were absent, manually add '$repo_name'"
    echo "  to the loop lists in mergepath's DEPLOYMENT.md +"
    echo "  REVIEW_POLICY.md."
    echo
    echo "NEXT STEPS (human-action):"
    echo "  1. Accept reviewer collaborator invites at:"
    echo "     https://github.com/$full_repo/invitations"
    echo "     (sign in once per agent identity)"
    echo "  2. Write the repo-local implementation spec:"
    echo "     $target/specs/$repo_name.md"
    echo "     Canonical PRDs live in nathanjohnpayne/docs/projects/$repo_name/prds/"
    echo "  3. Populate Phase 0 / Phase 1 issues via the create-issues.sh"
    echo "     skeleton: $target/scripts/gh-projects/examples/$repo_name/"
    echo "  4. Set provider-level spend caps before pasting LLM API keys:"
    echo "     - https://platform.openai.com/account/limits"
    echo "     - https://console.anthropic.com/settings/limits"
    echo "  5. Drive Sprint 0 PR #1 through the Phase 4 review flow."
    echo
    echo "DOC: docs/agents/bootstrap-runbook.md (in mergepath) explains every"
    echo "     stage above and how to debug or resume on failure."
    echo
  } >>"$_bs_summary_tmp"

  # Emit to stdout.
  cat "$_bs_summary_tmp"

  # Append to the bootstrap log file (audit trail). Skipped under
  # dry-run since the log is just an [DRY-RUN] transcript at that
  # point; appending the summary would mislead a future reader into
  # thinking a real run happened.
  if [ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ] && [ -n "${BOOTSTRAP_LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$BOOTSTRAP_LOG_FILE")"
    cat "$_bs_summary_tmp" >>"$BOOTSTRAP_LOG_FILE"
  elif [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ] && [ -n "${BOOTSTRAP_LOG_FILE:-}" ]; then
    # In dry-run, still append a marker so the test fixture can verify
    # the summary path was exercised. Keep the marker prefixed with
    # [DRY-RUN] so it can't be mistaken for a real run record.
    mkdir -p "$(dirname "$BOOTSTRAP_LOG_FILE")"
    {
      echo "[DRY-RUN] --- bootstrap summary (dry-run; not appended verbatim) ---"
      sed 's/^/[DRY-RUN] /' "$_bs_summary_tmp"
    } >>"$BOOTSTRAP_LOG_FILE"
  fi

  rm -f "$_bs_summary_tmp"
}
