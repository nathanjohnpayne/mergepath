#!/usr/bin/env bash
# scripts/bootstrap/github-infra.sh — bootstrap wizard stage C.
# Per #156 sub-C / #205.
#
# Responsibilities (in order):
#   1. `gh repo create --source=.` against the target dir, then a
#      separate `git push -u origin HEAD` (sub-B already ran `git init`
#      + initial commit; this step creates the remote and pushes the
#      bootstrap commit). Legitimate push to main on a greenfield
#      remote — the `gh-pr-guard.sh` "never push to main" hook does NOT
#      apply because there's no `main` to protect yet. The two halves
#      are separate commands so the create can be checkpointed the
#      moment it succeeds and a failed push stays retryable (#790) —
#      both run under the SAME verified author credential, the create
#      via bootstrap::run_author_gh and the push via
#      bootstrap::run_author_git.
#   2. Seed the 19 canonical labels (needs-external-review,
#      needs-human-review, policy-violation, human-hold,
#      human-action, decision-needed, agent-action, phase-0..4,
#      size:S/M/L, priority:critical/high/normal/low).
#      Eliminates the first-PR "label not found" friction.
#   3. Invite reviewer-identity collaborators (claude / cursor /
#      codex per BOOTSTRAP_INPUT_REVIEWERS). Each invite is async;
#      the wizard pauses for the human to accept the biometric on
#      each agent's GitHub session.
#   4. Provision the REVIEWER_ASSIGNMENT_TOKEN repo secret. Two
#      paths: reuse an existing 1Password item if present, OR
#      prompt the human to mint a fine-grained PAT.
#   5. Prompt for and provision other LLM secrets
#      (ANTHROPIC_API_KEY, OPENAI_API_KEY) with skip option.
#
# Test discipline:
#   Every gh / op / git call goes through bootstrap::run. Tests
#   exercise this stage via a PATH-shimmed `gh` that records its
#   invocations to a log file, so the test fixture can assert the
#   exact command shape + flag set without contacting GitHub.
#
# Reads (set by the wizard):
#   $TARGET_DIR                Local path of the new repo.
#   $BOOTSTRAP_REPO_OWNER      GitHub owner (default: nathanjohnpayne).
#   $BOOTSTRAP_INPUT_REPO_NAME New repo name.
#   $BOOTSTRAP_INPUT_DESCRIPTION One-line description for gh repo create.
#   $BOOTSTRAP_INPUT_VISIBILITY public|private.
#   $BOOTSTRAP_INPUT_REVIEWERS Comma-separated agent names (claude,cursor,codex).
#
# Env overrides for tests:
#   BOOTSTRAP_SKIP_SECRETS=1            skip steps 4+5 (no live PAT lookup)
#   BOOTSTRAP_STRICT_SECRETS=1          fail the stage when REVIEWER_ASSIGNMENT_TOKEN
#                                       cannot be provisioned (default: record the
#                                       miss + continue; summary surfaces it)
#   BOOTSTRAP_REVIEWER_PAT_VALUE=...    supply the PAT inline (path c) for tests
#   BOOTSTRAP_SKIP_INVITE_PAUSE=1       don't wait for "press enter to continue"
#   BOOTSTRAP_SKIP_AUTHOR_TOKEN=1       tests only: run gh shim directly instead
#                                       of the token-verifying author wrapper
#
# Side effects via bootstrap::run (so --dry-run is correct).

set -euo pipefail

# Canonical label set. Each entry: name|color|description.
#
# The separator is `|`, NOT `:`. The original `name:color:description`
# encoding split on the first two colons, which structurally cannot
# express a label name that itself contains a colon — and the whole
# shared `size:` / `priority:` taxonomy does. Under the old format
# "size:S:c2e0c6:Small..." parsed as name="size", color="S", which is
# not valid hex, so `gh label create` would have failed the entry
# outright. `|` appears in no label name, color or description here,
# and bootstrap::_seed_labels rejects a malformed entry rather than
# creating a mis-parsed label.
#
# Colors picked to be distinguishable in the GitHub UI light + dark
# themes.
#
# The `size:` / `priority:` entries are the fleet-shared subset agreed
# in the 2026-09-04 backlog audit: the three universal size buckets and
# the four priority levels, seeded so a new repo starts on the same
# scale the rest of the fleet uses. Names, colors and descriptions are
# byte-identical to mergepath's own labels — that is the point, and a
# drifted description is what makes a shared label stop meaning one
# thing. `size:XL` is deliberately absent: it existed in
# nathanpaynedotcom and was never applied to a single issue.
#
# Deliberately NOT seeded: `area:*`, `status:*` and the repo-local
# `type:*` values. Those are per-repo vocabulary; imposing the hub's
# nine-area scheme on a repo with four open issues is bureaucracy, not
# standardization.
BOOTSTRAP_LABELS=(
  "needs-external-review|bf0606|External review required before merge"
  "needs-human-review|7057ff|Awaiting human triage or decision"
  "policy-violation|b60205|Blocked by review-policy.yml violation"
  "human-hold|000000|Hard merge freeze - human-remove-only; supersedes all gates"
  "human-action|0e8a16|Requires human attention"
  "decision-needed|e99695|Needs a human decision before work proceeds (issue triage, not a PR merge gate)"
  "agent-action|1d76db|Agent task — not blocked on human"
  "phase-0|c5def5|Phase 0: foundations"
  "phase-1|bfd4f2|Phase 1: core"
  "phase-2|bfd4f2|Phase 2"
  "phase-3|bfd4f2|Phase 3"
  "phase-4|bfd4f2|Phase 4"
  "size:S|c2e0c6|Small: one or a few files, straightforward verification. Calibrated to nathanpaynedotcom#942/#849."
  "size:M|fef2c0|Medium: real design choice plus tests across a subsystem. Calibrated to nathanpaynedotcom#881/#825."
  "size:L|f9d0c4|Large: crosses subsystems or changes a depended-on contract. Calibrated to nathanpaynedotcom#900."
  "priority:critical|B60205|Broken now on the merge path, dated evidence, no workaround. Expect this to be empty."
  "priority:high|D93F0B|Measured live impact, or it blocks a named issue. Cite that evidence in the issue."
  "priority:normal|8B949E|Default. Worth doing; no observed live impact, or it fails in the safe direction."
  "priority:low|D4D8DD|Would not be missed. A candidate for closure at the next audit if still untouched."
)

# 1Password reference for the REVIEWER_ASSIGNMENT_TOKEN PAT (the
# nathanpayne-claude reviewer PAT). MUST be an item-UUID path, never a
# title path — title lookups don't reliably resolve, and the old
# title-based default (the item titled REVIEWER_ASSIGNMENT_PAT)
# silently shipped repos without the secret (#734; CLAUDE.md § 1Password Reviewer PAT
# Lookup: "Always look a PAT up by 1Password item ID, never by item
# title"). Sub-step 4 prefers the session-cached
# $OP_PREFLIGHT_REVIEWER_PAT before probing this reference — but only
# when the cached PAT's owning agent ($OP_PREFLIGHT_AGENT) is among the
# wizard's selected reviewers; likewise the default reference below is
# the claude reviewer PAT and is only probed when claude is a selected
# reviewer (#755 round 2). Override via BOOTSTRAP_REVIEWER_PAT_OP_REF
# for tests / alternate vaults; an explicit override is taken as the
# caller vouching for the identity behind it.
BOOTSTRAP_REVIEWER_PAT_OP_REF_DEFAULT="op://Private/pvbq24vl2h6gl7yjclxy2hbote/token"
BOOTSTRAP_REVIEWER_PAT_OP_REF="${BOOTSTRAP_REVIEWER_PAT_OP_REF:-$BOOTSTRAP_REVIEWER_PAT_OP_REF_DEFAULT}"
BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY="reviewer-assignment-token"

# Resume checkpoint for step 1. `gh repo create` is the one irreversible
# act in this stage, and it runs FIRST — but the stage records completion
# only after step 5, so any later abort (the BOOTSTRAP_STRICT_SECRETS=1
# secret failure above all) left a created remote with nothing recording
# that it had been created. `--resume template-mirror` then re-entered
# the stage and would have called `gh repo create` on a name that already
# exists, and the wizard's preflight refused to start at all because the
# remote was there (#761 item 3).
#
# The checkpoint closes both halves: bootstrap::_create_remote_and_push
# skips the create when it is set, and the wizard's preflight tolerates
# the pre-existing remote on a --resume run when it is set. It is
# consulted by scripts/bootstrap-new-repo.sh, so it is stage-module
# surface, not a private constant.
#
# The recorded name is BOUND TO THE REPOSITORY it records — the bare
# prefix below is never written or matched on its own. A checkpoint that
# said only "this bootstrap created a remote" would relax both guards for
# ANY owner/name, and the target dir is not proof of the name: a resume
# picks the repo up from the positional argument and $BOOTSTRAP_REPO_OWNER,
# while --target-dir can hold the tree constant across both runs. A
# mistyped resume (`bootstrap-new-repo.sh other-repo --target-dir <same>
# --resume template-mirror`) would then sail past preflight, skip the
# create because "a" remote was created, and go on to seed labels, invite
# reviewers and write REVIEWER_ASSIGNMENT_TOKEN into a repository this
# bootstrap never touched. Binding the name makes the relaxation
# unreachable for any repo other than the one actually created, which is
# what docs/agents/bootstrap-runbook.md promises.
BOOTSTRAP_GITHUB_INFRA_REMOTE_CHECKPOINT_PREFIX="github-infra:remote-created"

# The repo-bound checkpoint name for <owner>/<name>. Both consumers (the
# stage's step 1 and the wizard's preflight) MUST build the name through
# this helper so the two can never drift apart into a false match.
bootstrap::github_infra_remote_checkpoint() {
  printf '%s:%s\n' "$BOOTSTRAP_GITHUB_INFRA_REMOTE_CHECKPOINT_PREFIX" "$1"
}

# Out-parameter of bootstrap::_provision_reviewer_assignment_token: the
# SPECIFIC failure message for the path it took on the CURRENT call, or
# "" when that path published none. The stage-level caller reads it
# through bootstrap::_record_reviewer_token_stage_failure so its own keyed
# record under $BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY does not clobber
# the specific reason (#761).
#
# Every failing path now publishes one — no PAT available with prompts
# skipped, human declined to paste one, `gh secret set` itself failing,
# the author write path failing before `gh secret set` ever ran (#782),
# and the temp dir for that call's trace + capture files failing to
# allocate, in which case no write is attempted at all (#790). The
# gh-failed and pre-gh cases are told apart by positive proof that gh was
# reached, never by the rc, which both layers can return alike. The
# generic fallback in the recorder is therefore defence in depth for a
# future path that forgets to publish, not a live branch.
#
# Reset unconditionally on entry to that function — never trusted across
# calls. That reset is what keeps the two required behaviours from
# fighting each other; see the helper below.
BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON=""

# Message-field prefix stamped onto a recorded warning once a later
# attempt in the same bootstrap fixes it (#761). This is the WIRE FORMAT
# of the "${BOOTSTRAP_STATE_FILE}.warnings" sidecar, not a private
# constant: board-and-summary.sh's summary renderer keys its RESOLVED
# block off the same literal, and tests/test_bootstrap_github_infra.sh
# pins the two spellings equal.
BOOTSTRAP_WARNING_RESOLVED_MARKER="RESOLVED: "

# Agent names scripts/op-preflight.sh will accept for `--agent`. MUST
# stay equal to the set its reviewer_pat_item_for() knows — anything
# else exits 1 with "unknown agent". The wizard's --reviewers flag takes
# an unvalidated CSV, so a remediation hint that echoes a selection back
# as `--agent <name>` has to filter it through this list or it can print
# a command that cannot run (#761).
# tests/test_bootstrap_github_infra.sh pins this equal to op-preflight's
# own list so a new agent added there can't silently go missing here.
BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS="claude cursor codex"

bootstrap::stage_github_infra() {
  bootstrap::stage_banner "github-infra"

  local repo_name owner full_repo target visibility description reviewers
  repo_name=$(bootstrap_input repo_name)
  owner="${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}"
  full_repo="$owner/$repo_name"
  target=${TARGET_DIR:?TARGET_DIR not set by wizard}
  visibility=$(bootstrap_input visibility)
  description=$(bootstrap_input description)
  reviewers=$(bootstrap_input reviewers)

  # Per-step rc capture so the stage propagates failures cleanly
  # (same pattern as stage B sub-#233 round 4).
  local step_rc=0

  # GitHub writes in this stage are author-attributed. Each call goes
  # through bootstrap::run_author_gh / bootstrap::author_gh, which uses
  # scripts/gh-as-author.sh to verify the author token for the single
  # command. There is no stage-scope keyring mutation and therefore no
  # restore work to perform on failure paths.
  bootstrap::_restore_active_if_needed() {
    :
  }

  # Step 1: create the remote + push the bootstrap commit.
  bootstrap::_create_remote_and_push \
    "$full_repo" "$visibility" "$description" "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "github-infra: repo create / push failed (rc=$step_rc)"
    bootstrap::_restore_active_if_needed
    return "$step_rc"
  fi

  # Step 2: seed labels.
  # NOTE: _seed_labels swallows per-label failures (warn + continue
  # to the next label) and never returns non-zero, so the if-block
  # below cannot fire today. The structure is kept for symmetry with
  # the other steps + as a guardrail: a future change that makes the
  # helper bubble up rc gets failure propagation for free.
  bootstrap::_seed_labels "$full_repo" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "github-infra: label seeding failed (rc=$step_rc)"
    bootstrap::_restore_active_if_needed
    return "$step_rc"
  fi

  # Step 3: invite reviewer collaborators.
  # Same soft-fail semantics as _seed_labels — per-invite failures
  # warn + continue. A bad reviewer identity shouldn't block the
  # bootstrap; the summary surfaces the gap.
  bootstrap::_invite_reviewers "$full_repo" "$reviewers" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "github-infra: reviewer invitations failed (rc=$step_rc)"
    bootstrap::_restore_active_if_needed
    return "$step_rc"
  fi

  # Step 4+5: provision secrets (REVIEWER_ASSIGNMENT_TOKEN + optional
  # LLM keys). Skippable in tests / for repos that don't need them.
  if [ "${BOOTSTRAP_SKIP_SECRETS:-0}" = "1" ]; then
    bootstrap::log "secret provisioning skipped (BOOTSTRAP_SKIP_SECRETS=1)"
  else
    bootstrap::_provision_reviewer_assignment_token "$full_repo" "$reviewers" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      # By default secret failures are recorded-but-not-fatal —
      # workflows will fail loudly on the first PR if the token isn't
      # set, and the end-of-run summary carries the recorded warning
      # (#734). We don't want to block the bootstrap on the human
      # finding a PAT. BOOTSTRAP_STRICT_SECRETS=1 upgrades the miss
      # to a stage failure for callers that must not ship without it.
      if [ "${BOOTSTRAP_STRICT_SECRETS:-0}" = "1" ]; then
        bootstrap::err "github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=$step_rc) and BOOTSTRAP_STRICT_SECRETS=1 — failing the stage"
        # Persist the failure to the warnings sidecar even though the
        # stage is about to fail fatally. Without this, a `gh secret
        # set` failure that happens AFTER a PAT was obtained (as
        # opposed to the "no PAT available" sub-path, which already
        # records its own warning before returning) vanishes from
        # `.bootstrap-state.warnings` the moment the stage aborts —
        # a later --resume (or a human auditing the sidecar) has no
        # record the failure ever happened.
        bootstrap::_record_reviewer_token_stage_failure "$step_rc" \
          "BOOTSTRAP_STRICT_SECRETS=1 failed the stage — fix and re-run with --resume template-mirror"
        bootstrap::_restore_active_if_needed
        return "$step_rc"
      fi
      bootstrap::_record_reviewer_token_stage_failure "$step_rc" \
        "workflows will require manual secret-set on first PR"
      step_rc=0
    fi

    bootstrap::_provision_llm_secrets "$full_repo" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::warn "github-infra: LLM secret provisioning hit errors (rc=$step_rc); the affected workflows can be re-tried manually"
      step_rc=0
    fi
  fi

  # ----- end author-identity wrap: always-restore -----
  bootstrap::_restore_active_if_needed

  bootstrap::record_stage "github-infra"
  return 0
}

# --- internal helpers ------------------------------------------------------

bootstrap::_create_remote_and_push() {
  local full_repo=$1 visibility=$2 description=$3 target=$4

  # Sanity: sub-B's _init_target_git must have run. If the target has
  # no .git/ we can't push.
  #
  # Skip the existence check in dry-run mode — sub-B's `git init`
  # call also doesn't actually run under --dry-run (bootstrap::run
  # prints instead of executing), so the `.git/` directory wouldn't
  # exist in the dry-run plan either. The check is a safety net for
  # live runs where sub-B SHOULD have created it.
  if [ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ] && [ ! -d "$target/.git" ]; then
    bootstrap::err "github-infra: $target has no .git/ — did stage B (template-mirror) run? Use --resume template-mirror to retry."
    return 2
  fi

  # Idempotent re-entry (#761 item 3). An earlier attempt in this same
  # bootstrap already created the remote, then the stage aborted further
  # down. `gh repo create` cannot be repeated against an existing name,
  # so skip it — but only it. The push below still runs, because the
  # checkpoint records the CREATE and nothing more: the abort may well
  # have been the push itself (#790), and re-pushing a branch the remote
  # already has is a no-op that exits 0. (If the operator has since
  # DELETED the remote, the push and the subsequent label / invite /
  # secret calls fail loudly against the missing repo — remove the
  # .bootstrap-state.checkpoints sidecar to force a fresh create.)
  #
  # The lookup is for THIS $full_repo, not for "a remote was created":
  # a resume that names a different repo in the same target dir must
  # still create its own remote rather than inherit the earlier run's
  # skip and operate on somebody else's repository.
  local create_needed=1
  if bootstrap::has_checkpoint "$(bootstrap::github_infra_remote_checkpoint "$full_repo")"; then
    bootstrap::log "github-infra: remote $full_repo was already created by an earlier attempt in this bootstrap (resume checkpoint) — skipping gh repo create, retrying the push"
    create_needed=0
  fi

  if [ "$create_needed" = "1" ]; then
    # The visibility flag maps to gh's --public / --private / --internal.
    local vis_flag
    case "$visibility" in
      public)   vis_flag="--public"   ;;
      private)  vis_flag="--private"  ;;
      internal) vis_flag="--internal" ;;
      *)
        bootstrap::err "github-infra: unsupported visibility '$visibility' (expected public/private/internal)"
        return 2
        ;;
    esac

    # Create and push are SEPARATE commands on purpose (#790). As one
    # `gh repo create --source --push` they share a single exit code, and
    # a push that fails on a transient network or credential error — with
    # the repository already created server-side — returned non-zero
    # before any checkpoint was written. The remote existed, nothing
    # recorded it, and the documented `--resume template-mirror` retry
    # was then refused by preflight's existing-remote check: the exact
    # unrecoverable state the checkpoint was added to prevent, reached
    # through the one failure most likely to be transient.
    #
    # Split, each command's rc means one thing. `gh repo create --source`
    # (no --push) creates the repository and wires it up as `origin` in
    # the target tree; its success is the irreversible act and is
    # checkpointed immediately, before anything else can fail. The push
    # is then an ordinary repeatable step that any re-entry retries.
    local create_rc=0
    bootstrap::run_author_gh "create remote" \
      repo create "$full_repo" \
        "$vis_flag" \
        --description "$description" \
        --source="$target" || create_rc=$?
    if [ "$create_rc" -ne 0 ]; then
      return "$create_rc"
    fi

    # Record the irreversible half BEFORE anything downstream — the push
    # included — can abort the stage. bootstrap::record_checkpoint is a
    # no-op under --dry-run, so a dry run never claims a remote it did
    # not create. The record names the repo that was actually created,
    # which is what both consumers match on.
    #
    # A live write that does NOT land fails the stage right here, before
    # the push. The stage runs under `|| stage_rc=$?`, so errexit is
    # disabled through this call chain and an unchecked append would
    # simply carry on — straight into the state this whole checkpoint
    # exists to prevent. The remote is already created; if anything
    # later aborts with nothing recording it, preflight refuses the
    # documented `--resume template-mirror` retry and the create cannot
    # be repeated either. Stopping on the spot leaves one unrecorded
    # remote and a message naming it, which is recoverable; carrying on
    # gambles the whole run on nothing else failing.
    local checkpoint_name checkpoint_file
    checkpoint_name="$(bootstrap::github_infra_remote_checkpoint "$full_repo")"
    checkpoint_file="${BOOTSTRAP_STATE_FILE:-}.checkpoints"
    if ! bootstrap::record_checkpoint "$checkpoint_name"; then
      bootstrap::err "github-infra: the remote $full_repo was CREATED, but the resume checkpoint could not be written to $checkpoint_file"
      bootstrap::err "github-infra: failing the stage here rather than pushing on — an abort later with no checkpoint leaves a remote that exists, a create that cannot be repeated, and a --resume that preflight refuses"
      bootstrap::err "github-infra: fix the sidecar (unwritable path / full disk) or append the line '$checkpoint_name' to $checkpoint_file by hand, then re-run with --resume template-mirror"
      return 1
    fi
  fi

  # Push the bootstrap commit. This legitimately populates main on a
  # greenfield remote; gh-pr-guard.sh's "never push to main" invariant
  # doesn't apply because there's no protected main yet — we're creating
  # it. (The hook only fires on pre-existing repos.)
  #
  # `HEAD` rather than a hardcoded `main` so the push follows whatever
  # branch stage B's `git init -b main` left checked out, and `-u` sets
  # the upstream `gh repo create --push` used to set. Re-running against
  # an already-pushed remote is an "Everything up-to-date" no-op.
  #
  # bootstrap::run_author_git, NOT bootstrap::run: splitting the create
  # from the push must not split them off the author credential. As one
  # `gh repo create --source --push`, the single bootstrap::run_author_gh
  # call covered both halves — gh pushed under the author token
  # scripts/gh-as-author.sh had resolved and verified. A bare
  # bootstrap::run would create the repository with that token and then
  # push with the machine's ambient credential-helper state instead:
  # failing or prompting on a clean or non-author setup, and — where
  # another configured account has access — populating this new repo's
  # main under the wrong identity. The helper keeps the two halves on
  # one verified credential, which is the whole point of the
  # author/reviewer separation.
  local push_rc=0
  bootstrap::run_author_git "push bootstrap commit to $full_repo" \
    -C "$target" push -u origin HEAD || push_rc=$?
  if [ "$push_rc" -ne 0 ]; then
    bootstrap::err "github-infra: the remote $full_repo EXISTS (created and checkpointed) but the bootstrap commit did not push (rc=$push_rc)"
    bootstrap::err "github-infra: fix the push cause (network / git credentials) and re-run with --resume template-mirror — the checkpoint makes the retry skip the create and repeat only the push"
    return "$push_rc"
  fi
}

bootstrap::_seed_labels() {
  local full_repo=$1
  local spec name color desc

  for spec in "${BOOTSTRAP_LABELS[@]}"; do
    # Field-split on '|' — name|color|description. Both `name` and
    # `description` may contain colons (the whole `size:` / `priority:`
    # taxonomy does), which is why the separator is not ':'. Capture
    # the first two splits and let the rest be the description, so a
    # description containing '|' would still round-trip.
    # Require BOTH separators before splitting. `${var%%|*}` and
    # `${var#*|}` return the input UNCHANGED when the separator is
    # absent, so a one-separator entry does not fail — it silently
    # aliases two fields onto one value. "future-label|abcdef" would
    # otherwise parse as color=abcdef AND desc=abcdef, pass a
    # colour-only check, and create a label with its colour copied into
    # its description. The glob tests the shape before any field is
    # trusted; a description may still contain '|' and round-trips.
    case "$spec" in
      *"|"*"|"*) : ;;
      *)
        bootstrap::record_warning "github-infra: label spec '$spec' is malformed (expected name|color|description — both '|' separators required) — skipped, label NOT created"
        continue
        ;;
    esac

    name=${spec%%|*}
    local rest=${spec#*|}
    color=${rest%%|*}
    desc=${rest#*|}

    # Reject a malformed entry rather than creating a mis-parsed label.
    # A separator typo used to be silently survivable: the old ':'
    # format turned "size:S:c2e0c6:..." into a label named `size` with
    # colour `S`. Validating the parsed colour is what makes that class
    # of edit fail at the entry instead of at the API, and a bad entry
    # must not take the other 18 labels down with it.
    if [ -z "$name" ] || [ -z "$desc" ] || ! printf '%s' "$color" | grep -qE '^[0-9a-fA-F]{6}$'; then
      bootstrap::record_warning "github-infra: label spec '$spec' is malformed (expected name|color|description with a 6-digit hex colour) — skipped, label NOT created"
      continue
    fi

    # --force makes the operation idempotent: existing labels get
    # their color/description updated instead of erroring.
    bootstrap::run_author_gh "label create: $name" \
      label create "$name" \
        --repo "$full_repo" \
        --color "$color" \
        --description "$desc" \
        --force \
      || {
        # Single label failure is non-fatal — record and continue with
        # the rest. This uses record_warning, NOT warn: bootstrap::warn
        # only writes to stderr, so a failed create scrolled past while
        # the stage summary still reported the full label count as done
        # (CodeRabbit, #1182). Recorded warnings surface in the summary,
        # which is where the operator actually reads the outcome. No key
        # — several labels can fail independently and a keyed record
        # would have each one clobber the last.
        bootstrap::record_warning "github-infra: label '$name' create failed on $full_repo (continuing with remaining labels)"
      }
  done
}

bootstrap::_invite_reviewers() {
  local full_repo=$1 reviewers_csv=$2
  local agent login

  # Split CSV into individual agent names. Use a glob-safe split:
  # `set -f` disables pathname expansion so an agent name that
  # happened to contain `*` or `?` (unlikely but possible) doesn't
  # get word-globbed into matching paths. IFS is scoped via local
  # and restored explicitly after the split. (CodeRabbit Minor on
  # #239 round 1 + ShellCheck SC2086 caught the unprotected split.)
  local old_ifs="$IFS"
  set -f
  IFS=','
  # shellcheck disable=SC2086 # intentional word-split under -f
  set -- $reviewers_csv
  set +f
  IFS="$old_ifs"

  for agent in "$@"; do
    agent=$(printf '%s' "$agent" | tr -d ' ')
    [ -z "$agent" ] && continue
    login="nathanpayne-$agent"

    bootstrap::run_author_gh "invite collaborator: $login (write)" \
      api -X PUT "repos/$full_repo/collaborators/$login" \
        -f permission=write \
      || {
        # Non-existent agent identity, permission issue, etc. — log
        # and continue. The summary surfaces the gap.
        bootstrap::warn "github-infra: invitation to '$login' failed (continuing)"
      }
  done

  # Pause for the operator to accept each invite via the agent
  # account's GitHub UI. Skippable in tests + non-interactive runs.
  if [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" != "1" ] \
     && [ "${BOOTSTRAP_SKIP_INVITE_PAUSE:-0}" != "1" ] \
     && [ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ]; then
    echo
    echo "Reviewer-identity collaborator invitations sent."
    echo "Each invitee account needs to accept via:"
    echo "  https://github.com/$full_repo/invitations"
    local reply
    read -r -p "Press Enter once all invitations are accepted (or 'skip' to continue): " reply
    if [ "${reply:-}" = "skip" ]; then
      bootstrap::warn "github-infra: invite-acceptance pause was skipped — subsequent agent-review steps may fail until invitations are accepted"
    fi
  fi
}

# True iff agent name $1 (e.g. "claude") appears in the wizard's
# comma-separated reviewers selection $2. Spaces are stripped the same
# way _invite_reviewers strips them, so "claude, cursor" matches.
bootstrap::_reviewer_selected() {
  local agent=$1 reviewers_csv
  reviewers_csv=$(printf '%s' "$2" | tr -d ' ')
  case ",$reviewers_csv," in
    *",$agent,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Record the stage-level REVIEWER_ASSIGNMENT_TOKEN provisioning failure,
# keeping the callee's specific reason when it had one (#761).
#
# The stage and the provisioning helper both write under the SAME warning
# key, and bootstrap::record_warning is replace-by-key: it clears every
# line for the key before appending. A bare stage-level record therefore
# overwrote the specific reason the helper had just written ("no PAT
# available, prompts skipped" / "human declined to provide a PAT") with a
# generic "provisioning failed (rc=N)" — and since the resolver preserves
# whatever text is outstanding at resolution time, the audit trail this
# whole change exists for could no longer say WHICH failure happened.
#
# The fix carries the reason forward rather than declining to overwrite.
# "Don't overwrite an existing record for this key" looks equivalent but
# is wrong: the sidecar survives --resume and carries no run marker or
# timestamp, so a stale line written by an EARLIER attempt is
# byte-indistinguishable from one this attempt just wrote. A blanket
# no-overwrite guard would pin the stale reason in place and silently
# drop the current failure — breaking record_warning's replacement
# contract exactly when the sidecar most needs to be current.
#
# $BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON is positive proof instead:
# the helper resets it on entry and sets it only on the paths where it
# actually recorded something, so it describes THIS call and nothing else.
# A later attempt that fails on a path recording no reason of its own
# leaves it empty, falls back to the generic message here, and replaces
# the stale record as before.
#
# $1 is the provisioning rc (only used by the generic fallback — the
# specific reasons already name their own cause); $2 is the stage-level
# consequence appended to whichever headline is used.
bootstrap::_record_reviewer_token_stage_failure() {
  local rc=$1 tail_note=$2
  local headline="${BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON:-}"
  if [ -z "$headline" ]; then
    headline="github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=$rc)"
  fi
  bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" \
    "$headline; $tail_note"
}

# Retire a recorded warning once a later attempt in the same bootstrap
# fixed the underlying problem — WITHOUT erasing the fact that it
# happened (#761). bootstrap::clear_warning on its own deletes the line,
# so an operator who hit a BOOTSTRAP_STRICT_SECRETS=1 abort and then
# fixed it via --resume loses every trace that the first attempt failed;
# the sidecar is also the audit trail a human reads weeks later. Replace
# the outstanding line for this key with a resolution record instead,
# stamped with $BOOTSTRAP_WARNING_RESOLVED_MARKER so the summary lists it
# under RESOLVED rather than RECORDED FAILURES.
#
# Keyed by the SAME key as the original warning, so a later
# bootstrap::record_warning for that key still replaces it cleanly (its
# clear_warning matches on the "@<key><TAB>" prefix, which this record
# preserves).
#
# The ORIGINAL failure message is preserved verbatim and merely prefixed
# with the marker; $2 is a short resolution note appended in brackets.
# Substituting a generic "something failed earlier" string would defeat
# the audit trail this record exists for: several distinct failures share
# the reviewer-assignment-token key (no PAT + prompts skipped, human
# declined to paste one, `gh secret set` itself failed), and an operator
# reading the sidecar weeks later has to be able to tell WHICH one
# happened.
#
# No-op unless there is an OUTSTANDING line for the key. "Outstanding"
# means a line for the key whose message does NOT already carry the
# resolved marker — two separate guards in one:
#   - a first-attempt success must not manufacture a resolution record
#     for a failure that never happened (no line for the key at all);
#   - a second successful attempt must not re-resolve a record the first
#     one already resolved, which would double-prefix the marker and
#     bury the original message one bracket deeper each time.
bootstrap::_resolve_recorded_warning() {
  local key=$1 note=$2
  if [ -z "${BOOTSTRAP_STATE_FILE:-}" ] || [ ! -f "${BOOTSTRAP_STATE_FILE}.warnings" ]; then
    return 0
  fi

  local warnings_file="${BOOTSTRAP_STATE_FILE}.warnings"
  local prefix="@${key}	"
  local line original="" found=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      # Already resolved on an earlier attempt — leave it exactly as is.
      "${prefix}${BOOTSTRAP_WARNING_RESOLVED_MARKER}"*) ;;
      "$prefix"*) original=${line#"$prefix"}; found=1; break ;;
    esac
  done <"$warnings_file"
  if [ "$found" != "1" ]; then
    return 0
  fi

  bootstrap::clear_warning "$key"
  mkdir -p "$(dirname "$warnings_file")"
  printf '@%s\t%s%s [%s]\n' \
    "$key" "$BOOTSTRAP_WARNING_RESOLVED_MARKER" "$original" "$note" >>"$warnings_file"
  bootstrap::log "recorded warning '$key' marked resolved in the end-of-run summary"
}

# Emit the operator-facing remediation for a REVIEWER_ASSIGNMENT_TOKEN
# miss. The secret has to hold a PAT belonging to one of the SELECTED
# reviewers: scripts/gh-as-author.sh verifies the identity of the author
# performing the write, never the token piped on its stdin, so nothing
# downstream catches a wrong-identity payload (#761). Naming the right
# token is therefore this hint's job.
#
# $OP_PREFLIGHT_REVIEWER_PAT is deliberately never recommended as-is.
# Reaching this path with that variable set is positive proof it was
# rejected — path a above installs the cached PAT whenever its owning
# agent is a selected reviewer, so a surviving miss means the identity
# check said no. Echoing it back would hand the operator the very token
# the stage just refused.
bootstrap::_emit_reviewer_token_remediation() {
  local full_repo=$1 reviewers_csv=$2

  # Name a concrete selected reviewer so the preflight line is
  # copy-pasteable. It must be an agent scripts/op-preflight.sh actually
  # accepts: that script hard-rejects any --agent outside the set its
  # reviewer_pat_item_for() knows (see $BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS
  # below), and the wizard does NOT validate --reviewers at parse time, so
  # the first CSV field can be a name preflight refuses. Emitting it
  # verbatim would hand the operator a remediation that exits 1 — a
  # dead end at exactly the moment they need a working command. Pick the
  # first field preflight accepts; when the selection names none, the
  # cached-PAT route does not exist at all and the branch below emits a
  # different remediation rather than a placeholder.
  local agent="" candidate
  for candidate in $(printf '%s' "$reviewers_csv" | tr -d ' ' | tr ',' ' '); do
    case " $BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS " in
      *" $candidate "*) agent="$candidate"; break ;;
    esac
  done

  if [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
    if [ -n "${OP_PREFLIGHT_AGENT:-}" ]; then
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: do NOT install the PAT currently in \$OP_PREFLIGHT_REVIEWER_PAT — it belongs to agent '$OP_PREFLIGHT_AGENT', which is not one of the selected reviewers ($reviewers_csv)"
    else
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: do NOT install the PAT currently in \$OP_PREFLIGHT_REVIEWER_PAT — \$OP_PREFLIGHT_AGENT is unset, so its owning identity could not be verified"
    fi
  fi
  if [ -n "$agent" ]; then
    # ONE `&&`-chained command on purpose. Emitting the re-preflight and
    # the `gh secret set` as two independent lines makes the mitigation
    # advisory prose: an operator who transcribes only the line that
    # performs the action — in a shell where preflight last ran for a
    # NON-selected agent — installs that rejected PAT, and nothing
    # downstream catches it (gh-as-author.sh verifies the author
    # performing the write, never the token on its stdin). Chaining makes
    # skipping the re-preflight impossible without editing the command.
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: fix: re-run credential preflight for a SELECTED reviewer and set the secret from that agent's cache — run as ONE command, the preflight is not optional:"
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN:   eval \"\$(scripts/op-preflight.sh --agent $agent --mode review)\" && printf '%s' \"\$OP_PREFLIGHT_REVIEWER_PAT\" | scripts/gh-as-author.sh -- gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo $full_repo" # NO_BARE_GH_WRITE_EXEMPT: remediation hint echoed to the operator (routed through the token-verifying author wrapper), not an executed gh write
  else
    # No selected reviewer is an agent scripts/op-preflight.sh knows, so
    # there is no cached PAT to re-preflight for and the chained command
    # above has nothing valid to name. It used to be emitted anyway with
    # a literal `<selected-reviewer>` in the `--agent` slot, which an
    # operator cannot run as written: `<` and `>` are shell redirection
    # metacharacters, so pasting the line produces a redirect/syntax
    # error rather than the remediation, and hand-substituting one of the
    # supported agents installs a PAT belonging to an identity this repo
    # never invited — the exact wrong-identity install this hint exists to
    # prevent (#781 item 4).
    #
    # Emit the route that IS runnable verbatim instead. `gh secret set`
    # reads the value from stdin whenever `--body` is omitted, so the
    # operator supplies the invited reviewer's PAT directly and no
    # environment variable can silently substitute a different token.
    # That is also why dropping the `&&` chain is safe here: the chain
    # exists to stop $OP_PREFLIGHT_REVIEWER_PAT from being installed
    # without a re-preflight, and this command never reads it.
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: none of the selected reviewers ($reviewers_csv) is an agent scripts/op-preflight.sh can resolve a PAT for (it accepts: $BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS), so there is no cached PAT to install"
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: fix: mint a fine-grained PAT for one of the invited reviewer identities at https://github.com/settings/tokens/new (Contents:RW, Issues:RW, Pull Requests:RW, Metadata:R, scoped to $full_repo), then run this and supply that PAT when gh asks for it:"
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN:   scripts/gh-as-author.sh -- gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo $full_repo" # NO_BARE_GH_WRITE_EXEMPT: remediation hint echoed to the operator (routed through the token-verifying author wrapper), not an executed gh write
  fi
  bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: the stored secret must belong to one of the invited reviewers ($reviewers_csv) — the author wrapper verifies the account performing the write, NOT the token on its stdin, so a wrong-identity PAT installs silently and fails on the first PR"
}

bootstrap::_provision_reviewer_assignment_token() {
  local full_repo=$1 reviewers_csv=$2
  local pat=""

  # Reset the out-parameter FIRST, before any path can return. Deliberately
  # not `local`: the stage-level caller reads it after this function
  # returns. Clearing it on entry is what makes it describe THIS call — a
  # --resume attempt that fails on a path recording no specific reason must
  # NOT inherit the reason a previous attempt set, or the stage would
  # re-record a stale cause as if it were the current one.
  BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON=""

  # Path c (tests / explicit override): caller supplied the PAT
  # inline via env var.
  if [ -n "${BOOTSTRAP_REVIEWER_PAT_VALUE:-}" ]; then
    pat="$BOOTSTRAP_REVIEWER_PAT_VALUE"
    bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: using inline value from BOOTSTRAP_REVIEWER_PAT_VALUE"
  fi

  # Path a (preferred): reuse the reviewer PAT already cached by
  # scripts/op-preflight.sh in this session. No op call, no biometric
  # prompt (#734). The cached PAT belongs to whichever agent preflight
  # ran for — exported as $OP_PREFLIGHT_AGENT — which is NOT
  # necessarily one of the wizard's --reviewers selections. Installing
  # a mismatched PAT would make the secret authenticate as an
  # uninvited account and fail the reviewer-assignment workflows on
  # the first PR (#755 round 2). Reuse the cache only when its owning
  # agent is verifiably among the invited reviewers; otherwise fall
  # through to the op:// / prompt paths. An unset $OP_PREFLIGHT_AGENT
  # counts as a mismatch — identity we cannot verify is identity we
  # do not install.
  if [ -z "$pat" ] && [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
    if [ -n "${OP_PREFLIGHT_AGENT:-}" ] \
       && bootstrap::_reviewer_selected "$OP_PREFLIGHT_AGENT" "$reviewers_csv"; then
      pat="$OP_PREFLIGHT_REVIEWER_PAT"
      bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: reusing session-cached \$OP_PREFLIGHT_REVIEWER_PAT (agent '$OP_PREFLIGHT_AGENT' is a selected reviewer)"
    else
      bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: NOT reusing session-cached \$OP_PREFLIGHT_REVIEWER_PAT — it belongs to agent '${OP_PREFLIGHT_AGENT:-unknown}', not one of the selected reviewers ($reviewers_csv)"
    fi
  fi

  # Path a2: look up the PAT in 1Password by item UUID. The DEFAULT
  # reference resolves the nathanpayne-claude reviewer PAT, so it is
  # only valid when claude is among the selected reviewers; a custom
  # BOOTSTRAP_REVIEWER_PAT_OP_REF override is the caller vouching for
  # the identity behind it (#755 round 2). Never probed in dry-run:
  # the documented contract promises zero `op` side effects, and a
  # live probe can trigger biometric auth and retrieve the real PAT
  # (#755 round 3) — the dry-run branch below prints the plan instead.
  if [ -z "$pat" ] && [ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ] && command -v op >/dev/null 2>&1; then
    if [ "$BOOTSTRAP_REVIEWER_PAT_OP_REF" = "$BOOTSTRAP_REVIEWER_PAT_OP_REF_DEFAULT" ] \
       && ! bootstrap::_reviewer_selected claude "$reviewers_csv"; then
      bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: skipping the default 1Password probe — it resolves the claude reviewer PAT and claude is not one of the selected reviewers ($reviewers_csv)"
    else
      bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: probing 1Password at $BOOTSTRAP_REVIEWER_PAT_OP_REF"
      # Tolerate op timeouts — fall through to the prompt path if
      # 1Password is locked or the item doesn't exist.
      pat=$(op read "$BOOTSTRAP_REVIEWER_PAT_OP_REF" 2>/dev/null || true)
      if [ -n "$pat" ]; then
        bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: reusing existing 1Password item"
      fi
    fi
  fi

  # Dry-run purity (#755 round 2): a dry run intentionally carries no
  # credentials, so failing to resolve a PAT here is EXPECTED — it is
  # not the #734 "shipped without the secret" failure, and the target
  # repo does not even exist yet. Per the documented --dry-run
  # contract, print the would-happen plan under [DRY-RUN] markers,
  # write NO warnings sidecar, and do NOT fail BOOTSTRAP_STRICT_SECRETS.
  # (bootstrap::record_warning itself still mirrors
  # bootstrap::record_stage — both write when called in dry-run; this
  # path simply never calls it, because a credential miss in a
  # credential-free dry run is not a real warning.)
  if [ -z "$pat" ] && [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    echo "[DRY-RUN] REVIEWER_ASSIGNMENT_TOKEN: no PAT resolvable in this dry run (expected — dry runs carry no credentials)"
    echo "[DRY-RUN] REVIEWER_ASSIGNMENT_TOKEN: a live run would resolve the reviewer PAT (session cache -> 1Password -> interactive prompt) and pipe it via stdin to: scripts/gh-as-author.sh -- gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo $full_repo" # NO_BARE_GH_WRITE_EXEMPT: dry-run plan line echoed to the operator, not an executed gh write
    return 0
  fi

  # Path b: prompt the human to paste a fine-grained PAT. Skipped in
  # auto-prompt=skip mode (dry-run already returned above).
  if [ -z "$pat" ]; then
    if [ "${BOOTSTRAP_AUTO_PROMPT:-prompt}" = "skip" ]; then
      # Loud miss (#734): the old warn-and-continue made a broken op
      # reference ship unnoticed — the repo looked fully bootstrapped
      # but its first PR's reviewer-assignment workflows failed. Emit
      # ERROR-level lines with the remediation command, record the
      # miss for the end-of-run summary, and honor the strict knob.
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: NO PAT available and prompts are skipped — secret NOT set on $full_repo"
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: reviewer-assignment / agent-review workflows WILL FAIL on the first PR until it is set"
      bootstrap::_emit_reviewer_token_remediation "$full_repo" "$reviewers_csv"
      # Publish the reason as well as recording it: under
      # BOOTSTRAP_STRICT_SECRETS=1 this returns non-zero and the stage's
      # own keyed record would otherwise replace this line with a generic
      # one (#761).
      BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON="REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (no PAT available, prompts skipped) — set it manually before the first PR"
      bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON"
      if [ "${BOOTSTRAP_STRICT_SECRETS:-0}" = "1" ]; then
        return 1
      fi
      return 0
    fi
    echo
    echo "REVIEWER_ASSIGNMENT_TOKEN not found in 1Password."
    echo "Generate a fine-grained PAT at https://github.com/settings/tokens/new"
    echo "  Scopes: Contents:RW, Issues:RW, Pull Requests:RW, Metadata:R"
    echo "  Repository: $full_repo (scoped, not org-wide)"
    read -r -s -p "Paste the PAT (input hidden, blank to skip): " pat
    echo
    if [ -z "$pat" ]; then
      bootstrap::_emit_reviewer_token_remediation "$full_repo" "$reviewers_csv"
      # Same carry-forward as the prompts-skipped path above (#761).
      BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON="REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (human declined to provide a PAT) — set it manually before the first PR"
      bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON"
      if [ "${BOOTSTRAP_STRICT_SECRETS:-0}" = "1" ]; then
        return 1
      fi
      return 0
    fi
  fi

  # Set the repo secret. `gh secret set` reads stdin only when
  # `--body` is OMITTED entirely — passing `--body -` makes `-` the
  # literal body value (the dash isn't a stdin sentinel for gh's
  # secret subcommand). Codex P1 on #239 round 1 caught the bug:
  # the original code piped the PAT but also set `--body -`, so the
  # piped value was discarded and `-` would have been stored as
  # the secret. Strip --body entirely for the stdin path.
  #
  # We call `gh` DIRECTLY here rather than via bootstrap::run to
  # avoid logging the PAT value through the bootstrap log
  # transcript. bootstrap::run prints the full command line; that
  # would expose the piped-stdin path's command shape (fine) but
  # any future migration of secrets-to-args would leak the value
  # itself. The trade-off is that this call MUST be `-e`-safe so
  # the stage's explicit error handling still runs on failure — hence
  # the inline `|| set_rc=$?` on the pipeline below.
  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::run_author_gh "set REVIEWER_ASSIGNMENT_TOKEN secret (stdin pipe; len=${#pat})" \
      secret set REVIEWER_ASSIGNMENT_TOKEN --repo "$full_repo"
    return 0
  fi
  # Capture pipeline rc INLINE via `|| set_rc=$?`. Without the `||`,
  # the file-top `set -euo pipefail` would fire the moment the
  # pipeline returns non-zero, aborting the function BEFORE the
  # `local set_rc=$?` line ran. That bypassed every line below
  # (the err-log, the explicit `return $set_rc`, the success log)
  # and — more importantly — the caller's `bootstrap::_restore_active_if_needed`
  # only ran because the call site has `|| step_rc=$?` to defuse
  # set -e at the call. The inline `|| set_rc=$?` mirrors the
  # _provision_llm_secrets pattern + closes the gap nathanpayne-claude
  # caught on #239 round 2.
  #
  # The call is traced (bootstrap::author_gh_traced) because the rc alone
  # does not say WHICH layer failed. bootstrap::author_gh returns non-zero
  # both when `gh secret set` runs and fails and when the write never got
  # that far — scripts/gh-as-author.sh refusing on its byline pin or
  # failing to look up an author token, or the wrapper being missing
  # entirely. Recording the former's message for the latter points the
  # operator at the reviewer PAT they just supplied when the thing to
  # repair is AUTHOR authentication. The marker is the positive proof:
  # present only when gh itself was reached.
  #
  # Output is captured to a file rather than written straight to the
  # terminal so the pre-gh diagnostic can be PERSISTED as well as shown:
  # the wizard has no global stderr tee and bootstrap::run logs command
  # lines only, so an operator reading the sidecar after a resume or in a
  # later audit would otherwise find the record naming the author write
  # path with the wrapper's actual complaint — which token lookup failed,
  # which identity the byline pin wanted — nowhere on disk. Everything is
  # replayed to stderr immediately afterwards, so the live run reads
  # exactly as before (stdout folded into stderr as it already was).
  local set_rc=0 reached_dir reached_marker call_output gh_was_reached=0
  # A failed allocation must stop the write, not proceed with empty
  # paths. `set -e` is disabled inside this function (the stage calls it
  # as `... || step_rc=$?`), so an unchecked `mktemp -d` failure — TMPDIR
  # missing, unwritable, or full — would fall through with `reached_dir`
  # empty: the marker becomes `/gh-reached` and the capture `/output`. An
  # unprivileged run then fails on the redirect alone, with no marker, and
  # the branch below reports an AUTHOR-AUTHENTICATION failure for what is
  # really a broken temp dir — sending the operator to re-mint tokens. A
  # privileged run is worse: it performs the secret write and leaves
  # root-owned files at the filesystem root.
  #
  # Refusing here matches what the trace shim already does when it cannot
  # write the marker (exit 70): a caller that cannot record the boundary
  # must not perform an unattributable write. The miss is recorded like
  # every other cause under this key, so it is non-fatal by default and
  # fails the stage under BOOTSTRAP_STRICT_SECRETS=1.
  if ! reached_dir=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-secret-set.XXXXXX" 2>/dev/null) \
     || [ -z "$reached_dir" ] || [ ! -d "$reached_dir" ]; then
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: could not allocate a temporary directory under ${TMPDIR:-/tmp} (missing, unwritable, or full) — refusing to run the secret write without the trace + capture files that say which layer failed"
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: no secret-set call was attempted; fix TMPDIR and re-run with --resume template-mirror"
    BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON="REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (could not allocate a temporary directory under ${TMPDIR:-/tmp}, so the secret write was never attempted) — fix TMPDIR, then re-run or set the secret manually before the first PR"
    return 1
  fi
  reached_marker="$reached_dir/gh-reached"
  call_output="$reached_dir/output"
  printf '%s' "$pat" | bootstrap::author_gh_traced "$reached_marker" secret set REVIEWER_ASSIGNMENT_TOKEN --repo "$full_repo" >"$call_output" 2>&1 || set_rc=$?
  if [ -e "$reached_marker" ]; then
    gh_was_reached=1
  fi
  cat "$call_output" >&2
  # Persist the capture BEFORE the record is worded, because the record
  # may only point at the log if the append actually happened: no log
  # file configured, or nothing captured, and it did not. A warning
  # pointing at an entry that was never written is worse than one that
  # points nowhere, because it ends the operator's search.
  #
  # The pre-gh branch is the ONE that may persist. Its marker is absent,
  # which is positive proof that nothing in the pipeline ever exec'd gh;
  # the wrapper and the trace shim never read stdin, so no process that
  # could have seen the piped PAT produced a byte of this text. (Nor does
  # the wrapper chain print token material at all —
  # scripts/lib/gh-token-resolver.sh and scripts/identity-check.sh name
  # identities and sources, never values.) Once gh HAS run the capture
  # stays terminal-only: that branch's record claims nothing about the
  # log, so there is no false pointer to repair, and no reason to write
  # post-PAT-read output to a file that outlives the run.
  local diag_location="in the terminal output above"
  if [ "$set_rc" -ne 0 ] && [ "$gh_was_reached" != "1" ] \
     && bootstrap::append_log_diagnostic \
          "REVIEWER_ASSIGNMENT_TOKEN author write path failed before gh ran (rc=$set_rc)" \
          "$call_output"; then
    diag_location="in the run log"
  fi
  rm -rf "$reached_dir"
  if [ "$set_rc" -ne 0 ]; then
    # Publish the specific reason, exactly as the no-PAT and declined
    # paths above do. This path always returns non-zero, so the stage
    # ALWAYS records under the shared key — and without a reason the
    # record fell back to the generic "provisioning failed (rc=N)",
    # leaving the sidecar unable to say which of the causes sharing
    # this key actually happened. That is the one question the audit
    # trail exists to answer, and the runbook documents that it names
    # `gh secret set` itself failing (#782) — which it may only claim
    # when `gh secret set` actually ran.
    #
    # Unlike those paths this one records nothing itself: they return 0
    # under default (non-strict) semantics, so they must persist their
    # own warning or it is lost. A secret-set failure is always
    # propagated, so a self-record would only be overwritten moments
    # later by the stage's keyed record.
    if [ "$gh_was_reached" = "1" ]; then
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: secret set failed (rc=$set_rc)"
      BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON="REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (the gh secret-set call itself failed, rc=$set_rc) — set it manually before the first PR"
    else
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: the author-identity write path failed BEFORE gh ran (rc=$set_rc) — no secret-set call was attempted"
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: this is an AUTHOR-authentication failure ($(bootstrap::author_identity) token lookup / verification, or a missing $(bootstrap::author_wrapper)), NOT a problem with the reviewer PAT — see the lines above from the wrapper"
      BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_REASON="REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (the author write path failed before the gh secret-set call ran, rc=$set_rc — typically the author wrapper failing to resolve or verify a $(bootstrap::author_identity) token; the wrapper's own error is $diag_location) — repair author authentication, then set the secret manually before the first PR"
    fi
    return "$set_rc"
  fi
  # Note only — the original failure message is kept verbatim by the
  # resolver, so the sidecar still says WHICH failure this fixed.
  bootstrap::_resolve_recorded_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" \
    "fixed on a later attempt in this bootstrap: the secret is now set on $full_repo; no action needed"
  bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN set on $full_repo (len=${#pat})"
}

bootstrap::_provision_llm_secrets() {
  local full_repo=$1

  # The full set of optional LLM secrets the wizard knows how to
  # provision. Each entry: secret_name:prompt-friendly-description.
  # Add new entries here as upstream tooling needs them.
  local llm_secrets=(
    "ANTHROPIC_API_KEY:Anthropic API key for Claude calls (sk-ant-...)"
    "OPENAI_API_KEY:OpenAI API key for Codex / Cursor calls (sk-...)"
  )

  # Accumulate failure across the loop so a single LLM secret failure
  # doesn't abort the rest, but the function still returns non-zero
  # for the caller's accounting (CodeRabbit Major on #239 round 1).
  local any_fail=0

  local secret
  for secret in "${llm_secrets[@]}"; do
    local name=${secret%%:*}
    local desc=${secret#*:}

    if [ "${BOOTSTRAP_AUTO_PROMPT:-prompt}" = "skip" ] \
       || [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
      bootstrap::log "LLM secret $name: prompts skipped (dry-run or auto-prompt=skip)"
      continue
    fi

    echo
    echo "$desc"
    local value
    read -r -s -p "Paste $name (input hidden, blank to skip): " value
    echo
    if [ -z "$value" ]; then
      bootstrap::log "LLM secret $name: skipped"
      continue
    fi
    # Same --body fix as REVIEWER_ASSIGNMENT_TOKEN: omit --body so
    # gh reads from stdin instead of storing literal `-`. Codex P1
    # on #239 round 1 caught the bug for both secret paths.
    local set_rc=0
    printf '%s' "$value" | bootstrap::author_gh secret set "$name" --repo "$full_repo" >&2 || set_rc=$?
    if [ "$set_rc" -ne 0 ]; then
      bootstrap::warn "LLM secret $name: secret set failed (rc=$set_rc); continuing with remaining secrets"
      any_fail=1
      continue
    fi
    bootstrap::log "$name set on $full_repo (len=${#value})"
  done

  return "$any_fail"
}
