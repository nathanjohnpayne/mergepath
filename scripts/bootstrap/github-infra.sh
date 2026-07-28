#!/usr/bin/env bash
# scripts/bootstrap/github-infra.sh — bootstrap wizard stage C.
# Per #156 sub-C / #205.
#
# Responsibilities (in order):
#   1. `gh repo create --source=. --push` against the target dir
#      (sub-B already ran `git init` + initial commit; this step
#      creates the remote and pushes the bootstrap commit). Legitimate
#      push to main on a greenfield remote — the `gh-pr-guard.sh`
#      "never push to main" hook does NOT apply because there's no
#      `main` to protect yet.
#   2. Seed the 12 canonical labels (needs-external-review,
#      needs-human-review, policy-violation, human-hold,
#      human-action, decision-needed, agent-action, phase-0..4).
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

# Canonical label set. Each entry: name:hex-color:description.
# Format kept consistent with the existing matchline / mergepath
# label conventions. Colors picked to be distinguishable in the
# GitHub UI light + dark themes.
BOOTSTRAP_LABELS=(
  "needs-external-review:bf0606:External review required before merge"
  "needs-human-review:7057ff:Awaiting human triage or decision"
  "policy-violation:b60205:Blocked by review-policy.yml violation"
  "human-hold:000000:Hard merge freeze - human-remove-only; supersedes all gates"
  "human-action:0e8a16:Requires human attention"
  "decision-needed:e99695:Needs a human decision before work proceeds (issue triage, not a PR merge gate)"
  "agent-action:1d76db:Agent task — not blocked on human"
  "phase-0:c5def5:Phase 0: foundations"
  "phase-1:bfd4f2:Phase 1: core"
  "phase-2:bfd4f2:Phase 2"
  "phase-3:bfd4f2:Phase 3"
  "phase-4:bfd4f2:Phase 4"
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
        bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=$step_rc); BOOTSTRAP_STRICT_SECRETS=1 failed the stage — fix and re-run with --resume template-mirror"
        bootstrap::_restore_active_if_needed
        return "$step_rc"
      fi
      bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=$step_rc); workflows will require manual secret-set on first PR"
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

  # `gh repo create --source=. --push` legitimately populates main
  # on a greenfield remote. gh-pr-guard.sh's "never push to main"
  # invariant doesn't apply because there's no protected main yet —
  # we're creating it. (The hook only fires on pre-existing repos.)
  bootstrap::run_author_gh "create remote + push" \
    repo create "$full_repo" \
      "$vis_flag" \
      --description "$description" \
      --source="$target" \
      --push
}

bootstrap::_seed_labels() {
  local full_repo=$1
  local spec name color desc

  for spec in "${BOOTSTRAP_LABELS[@]}"; do
    # Field-split on ':' — name:color:description. `description` can
    # contain colons; capture only the first two splits and let the
    # rest be the description.
    name=${spec%%:*}
    local rest=${spec#*:}
    color=${rest%%:*}
    desc=${rest#*:}

    # --force makes the operation idempotent: existing labels get
    # their color/description updated instead of erroring.
    bootstrap::run_author_gh "label create: $name" \
      label create "$name" \
        --repo "$full_repo" \
        --color "$color" \
        --description "$desc" \
        --force \
      || {
        # Single label failure is non-fatal — log and continue with
        # the rest. The summary collects the count.
        bootstrap::warn "github-infra: label '$name' create failed (continuing with remaining labels)"
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
  # first field preflight accepts; fall back to a placeholder only when
  # the selection names none.
  local agent="" candidate
  for candidate in $(printf '%s' "$reviewers_csv" | tr -d ' ' | tr ',' ' '); do
    case " $BOOTSTRAP_REVIEWER_PREFLIGHT_AGENTS " in
      *" $candidate "*) agent="$candidate"; break ;;
    esac
  done
  if [ -z "$agent" ]; then
    agent="<selected-reviewer>"
  fi

  if [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
    if [ -n "${OP_PREFLIGHT_AGENT:-}" ]; then
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: do NOT install the PAT currently in \$OP_PREFLIGHT_REVIEWER_PAT — it belongs to agent '$OP_PREFLIGHT_AGENT', which is not one of the selected reviewers ($reviewers_csv)"
    else
      bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: do NOT install the PAT currently in \$OP_PREFLIGHT_REVIEWER_PAT — \$OP_PREFLIGHT_AGENT is unset, so its owning identity could not be verified"
    fi
  fi
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
  bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: the stored secret must belong to one of the invited reviewers ($reviewers_csv) — the author wrapper verifies the account performing the write, NOT the token on its stdin, so a wrong-identity PAT installs silently and fails on the first PR"
}

bootstrap::_provision_reviewer_assignment_token() {
  local full_repo=$1 reviewers_csv=$2
  local pat=""

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
      bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (no PAT available, prompts skipped) — set it manually before the first PR"
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
      bootstrap::record_warning "$BOOTSTRAP_REVIEWER_ASSIGNMENT_WARNING_KEY" "REVIEWER_ASSIGNMENT_TOKEN was NOT provisioned on $full_repo (human declined to provide a PAT) — set it manually before the first PR"
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
  local set_rc=0
  printf '%s' "$pat" | bootstrap::author_gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo "$full_repo" >&2 || set_rc=$?
  if [ "$set_rc" -ne 0 ]; then
    bootstrap::err "REVIEWER_ASSIGNMENT_TOKEN: secret set failed (rc=$set_rc)"
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
