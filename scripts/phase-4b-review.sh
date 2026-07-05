#!/usr/bin/env bash
# scripts/phase-4b-review.sh — Phase 4b AUTOMATED review orchestrator.
#
# REFERENCE IMPLEMENTATION (#<this-feature>). Replaces the human shuttle in
# REVIEW_POLICY.md § Phase 4b with an orchestrated, headless CLI review:
# select the external reviewer (≠ author), dispatch to the direction-
# specific adapter (codex exec / claude -p), then post the resulting
# verdict under the reviewer PAT via scripts/gh-as-reviewer.sh. An
# APPROVED review on the current HEAD from a non-author reviewer identity
# is exactly the "Phase 4b substitute" clearance the existing merge gate
# (scripts/codex-review-check.sh, codex.allow_phase_4b_substitute, #218)
# already accepts — so this script changes NO merge-gate code.
#
# Design: plans/automated-phase-4b-handoff.md.
#
# Usage:
#   scripts/phase-4b-review.sh <PR#> [--repo owner/repo]
#       [--reviewer nathanpayne-<agent>] [--author <agent>]
#       [--head <sha>] [--diff-file <path>] [--dry-run]
#
# Overrides (mostly for tests / non-git contexts):
#   --author    PR's authoring agent (claude|codex|...). Default: parsed
#               from the PR body `Authoring-Agent:` line.
#   --reviewer  force the external reviewer login (skips selection, but still
#               must differ from the authoring agent).
#   --head      HEAD sha. Default: gh api pulls/<n> .head.sha.
#   --diff-file pre-fetched unified diff (skips `gh pr diff`).
#   --dry-run   do everything EXCEPT post the review; print intended action.
#
# Env:
#   GH_TOKEN / op-preflight cache   reviewer-scoped token (auto-sourced).
#   CODEX_BIN / CLAUDE_BIN          adapter CLI overrides (tests).
#   P4B_GH_AS_REVIEWER              reviewer wrapper override (tests).
#   P4B_GH_AS_AUTHOR                author wrapper override (tests) — used
#                                   for the step-9 post-review issue writes.
#   P4B_HANDOFF                     manual handoff renderer override (tests).
#   P4B_ADAPTER_TIMEOUT_SECONDS     env override for the outer adapter-call
#                                   timeout; default is resolved per-adapter
#                                   from phase_4b_automation (900 when absent).
#   Timeout + effort are otherwise read from phase_4b_automation
#   (adapter_timeout_seconds / <adapter>_timeout_seconds / <adapter>_effort;
#   see p4b_resolve_adapter_timeout / p4b_resolve_adapter_effort) and passed to
#   the adapter via P4B_REVIEW_CLI_TIMEOUT_SECONDS / P4B_{CLAUDE,CODEX}_EFFORT.
#   A malformed or out-of-range config fails closed (exit 3).
#
# Exit codes:
#   0  APPROVED — review posted (or would post under --dry-run).
#   1  CHANGES_REQUESTED — review posted; the author must address findings.
#   3  usage / infrastructure error.
#   4  fell back to the manual handoff (adapter error/timeout, invalid
#      verdict, or no adapter for the selected reviewer). The chat-side
#      block from scripts/post-phase-4b-handoff.sh is emitted on stderr.
#   5  automation disabled or mode != local — caller uses the manual
#      handoff (today's behavior). Not an error.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=phase-4b/lib.sh
. "$ROOT/phase-4b/lib.sh"

# Phase 4b approval-loop accounting (#602). Sourced when present so the hook
# call sites below exist; a missing or unsourceable module simply leaves
# accounting off (the plain-summary review body posts unchanged). Advisory to
# safety: no accounting failure may block, fabricate, or re-code a review.
P4B_ACCT_AVAILABLE=false
if [ -r "$ROOT/phase-4b/accounting.sh" ]; then
  # shellcheck source=phase-4b/accounting.sh
  if . "$ROOT/phase-4b/accounting.sh"; then
    P4B_ACCT_AVAILABLE=true
  fi
fi
# True iff the module loaded AND phase_4b_automation.accounting.enabled is
# not false (defaults on under the disabled-by-default parent; this line is
# only reached when the parent automation is enabled).
p4b_acct_on() { [ "$P4B_ACCT_AVAILABLE" = true ] && p4b_acct_hook_active; }

# Whether THIS invocation's loop record has been appended to the loop log.
# Set after the pre-post record; consulted by the failure paths so a review
# that never actually posted is corrected instead of double-recorded.
P4B_ACCT_LOOP_RECORDED=false

# Per-invocation ledger-staging token (#615 Codex round 6). Exported so the
# render subshell (which stages the pending record on disk) and this process's
# later commit call agree on ownership: the two-phase commit only appends a
# pending record whose sidecar run id matches this value, so a stale record
# left by a prior crashed run is discarded instead of committed on the
# fail-open path. Generated once here; NEVER regenerated per hook call.
P4B_ACCT_RUN_ID="p4b-$$-$(date +%s 2>/dev/null || echo 0)-${RANDOM:-0}"
export P4B_ACCT_RUN_ID

# p4b_acct_mark_unposted <why>
# Correct the provisional accounting state when the review did NOT actually
# post (#615 Codex): amend this invocation's loop-log line (posted →
# not-posted, fail-closed with the reason) and discard the staged ledger
# record so local state never claims a phantom posted approval. Advisory —
# never alters review flow or exit codes.
p4b_acct_mark_unposted() {
  local why="$1"
  p4b_acct_on 2>/dev/null || return 0
  p4b_acct_hook_discard_pending_record || true
  if [ "${P4B_ACCT_LOOP_RECORDED:-false}" = true ]; then
    p4b_acct_hook_mark_last_loop_unposted "$why" \
      || p4b_warn "accounting: could not correct the unposted loop record (continuing)"
    P4B_ACCT_LOOP_RECORDED=false
  fi
  return 0
}

ADAPTER_DIR="$ROOT/phase-4b/adapters"
HANDOFF="${P4B_HANDOFF:-$ROOT/post-phase-4b-handoff.sh}"
GH_AS_REVIEWER="${P4B_GH_AS_REVIEWER:-$ROOT/gh-as-reviewer.sh}"
# Author wrapper for the step-9 issue writes (#672/#674): resolves AND
# identity-verifies the author PAT before each write, replacing manual
# token resolution (test override: P4B_GH_AS_AUTHOR).
GH_AS_AUTHOR="${P4B_GH_AS_AUTHOR:-$ROOT/gh-as-author.sh}"
# Outer adapter-call timeout. An explicit env override wins (tests/manual);
# otherwise it is resolved per-adapter from policy after the reviewer is chosen
# (see p4b_resolve_adapter_timeout). Captured here so the env override is not
# shadowed by the policy resolution below.
ADAPTER_TIMEOUT_ENV="${P4B_ADAPTER_TIMEOUT_SECONDS:-}"
ADAPTER_TIMEOUT=""

PR="" ; REPO="" ; REVIEWER="" ; AUTHOR="" ; HEAD="" ; DIFF_FILE="" ; DRY_RUN=false

usage() {
  echo "usage: phase-4b-review.sh <PR#> [--repo owner/repo] [--reviewer <login>] [--author <agent>] [--head <sha>] [--diff-file <path>] [--dry-run]" >&2
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --reviewer)  REVIEWER="${2:-}"; shift 2 ;;
    --author)    AUTHOR="${2:-}"; shift 2 ;;
    --head)      HEAD="${2:-}"; shift 2 ;;
    --diff-file) DIFF_FILE="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)   usage ;;
    -*) echo "phase-4b-review.sh: unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$PR" ]; then PR="$1"; else echo "unexpected arg: $1" >&2; usage; fi
      shift ;;
  esac
done

[ -n "$PR" ] || usage
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || p4b_die 3 "PR# must be a positive integer; got '$PR'"

# --- automation entry decision ---------------------------------------------
ENABLED="$(p4b_automation_field enabled)"; ENABLED="${ENABLED:-false}"
MODE="$(p4b_automation_field mode)"; MODE="${MODE:-local}"

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

emit_skip_json() {
  printf '{"pr_number":%s,"repo":%s,"automation_enabled":false,"skipped":true,"reason":%s}\n' \
    "$PR" "$(json_string "$REPO")" "$(json_string "$1")"
}

if [ "$ENABLED" != "true" ]; then
  p4b_log "phase_4b_automation.enabled != true — deferring to the manual handoff"
  emit_skip_json "automation-disabled"
  exit 5
fi
if [ "$MODE" != "local" ]; then
  p4b_log "phase_4b_automation.mode='$MODE' (not 'local') — deferring to the manual handoff"
  emit_skip_json "mode-not-local"
  exit 5
fi

command -v jq >/dev/null 2>&1 || p4b_die 3 "jq is required"

# Auto-source the op-preflight reviewer PAT only after the disabled/mode checks.
# The default disabled path must stay credential-free and exit 5 without
# touching 1Password/GitHub auth state.
if [ -r "$ROOT/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$ROOT/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
  load_preflight_env_vars
fi

# --- resolve repo / head / author ------------------------------------------
need_gh() { command -v gh >/dev/null 2>&1 || p4b_die 3 "gh is required for this path (or pass the matching override flag)"; }

if [ -z "$REPO" ]; then
  need_gh
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] || p4b_die 3 "could not resolve repo; pass --repo owner/name"
fi

if [ -z "$HEAD" ]; then
  need_gh
  HEAD="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)"
  [ -n "$HEAD" ] || p4b_die 3 "could not resolve HEAD sha for $REPO#$PR; pass --head"
fi

# Authoring agent: explicit override, else parse the PR body line. Required
# even when --reviewer is forced so the cross-agent invariant still applies.
if [ -z "$AUTHOR" ]; then
  need_gh
  body="$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""' 2>/dev/null || true)"
  AUTHOR="$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Authoring-Agent:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | head -n1)"
  [ -n "$AUTHOR" ] || p4b_die 3 "could not parse Authoring-Agent from PR body; pass --author"
fi

# --- select reviewer + adapter ---------------------------------------------
AUTHOR_AGENT="$(p4b_agent_of_login "$AUTHOR")"
if [ -z "$REVIEWER" ]; then
  REVIEWER="$(p4b_select_reviewer "$AUTHOR" || true)"
  [ -n "$REVIEWER" ] || p4b_die 3 "no external reviewer (≠ author '$AUTHOR') in available_reviewers"
fi
REVIEWER_AGENT="$(p4b_agent_of_login "$REVIEWER")"
if [ "$REVIEWER_AGENT" = "$AUTHOR_AGENT" ]; then
  p4b_die 3 "reviewer '$REVIEWER' matches authoring agent '$AUTHOR'; Phase 4b requires a different reviewer identity"
fi
ADAPTER="$(p4b_adapter_of_login "$REVIEWER")"
ADAPTER_SCRIPT="$ADAPTER_DIR/review-via-${ADAPTER}.sh"
DIRECTION="${AUTHOR_AGENT}->${ADAPTER}"

# --- resolve reviewer CLI runtime bounds from policy (#589) -----------------
# Fail closed on a malformed/out-of-range config rather than running the CLI
# mis-bounded or with an invalid effort.
RESOLVED_TIMEOUT="$(p4b_resolve_adapter_timeout "$ADAPTER")" \
  || p4b_die 3 "invalid phase_4b_automation timeout for adapter '$ADAPTER' (integer seconds in [${P4B_MIN_ADAPTER_TIMEOUT_SECONDS}, ${P4B_MAX_ADAPTER_TIMEOUT_SECONDS}] required)"
RESOLVED_EFFORT="$(p4b_resolve_adapter_effort "$ADAPTER")" \
  || p4b_die 3 "invalid phase_4b_automation effort for adapter '$ADAPTER'"
# Outer adapter-call bound: env override wins, else the policy-resolved value.
ADAPTER_TIMEOUT="${ADAPTER_TIMEOUT_ENV:-$RESOLVED_TIMEOUT}"
# Feed the effective bounds to the adapter via env, but only where the caller
# has not already set them (env override wins for tests/manual runs). The inner
# CLI timeout defaults to the SAME effective outer timeout (ADAPTER_TIMEOUT), so
# a P4B_ADAPTER_TIMEOUT_SECONDS override to extend a slow run reaches the adapter
# too and does not get shadowed by the policy value (#598 Codex P2).
: "${P4B_REVIEW_CLI_TIMEOUT_SECONDS:=$ADAPTER_TIMEOUT}"
export P4B_REVIEW_CLI_TIMEOUT_SECONDS
# EFFECTIVE_EFFORT is the value the adapter actually runs at — an existing
# P4B_{CLAUDE,CODEX}_EFFORT override is preserved by `:=`, so record THAT (not
# the policy-resolved value) in the review metadata (#598 Codex P3).
case "$ADAPTER" in
  claude) : "${P4B_CLAUDE_EFFORT:=$RESOLVED_EFFORT}"; export P4B_CLAUDE_EFFORT
          EFFECTIVE_EFFORT="$P4B_CLAUDE_EFFORT" ;;
  codex)  if [ -n "$RESOLVED_EFFORT" ]; then
            : "${P4B_CODEX_EFFORT:=$RESOLVED_EFFORT}"; export P4B_CODEX_EFFORT
          fi
          EFFECTIVE_EFFORT="${P4B_CODEX_EFFORT:-}" ;;
  *)      EFFECTIVE_EFFORT="$RESOLVED_EFFORT" ;;
esac

p4b_log "PR $REPO#$PR  HEAD=${HEAD:-?}  direction=$DIRECTION  reviewer=$REVIEWER  adapter=$ADAPTER  timeout=${ADAPTER_TIMEOUT}s  effort=${EFFECTIVE_EFFORT:-cli-default}  dry_run=$DRY_RUN"

# --- manual-handoff fallback -----------------------------------------------
fall_back_to_manual() {
  local why="$1"
  local handoff_ref="$PR"
  [ -n "$REPO" ] && handoff_ref="${REPO}#${PR}"
  p4b_warn "falling back to the manual Phase 4b handoff: $why"
  # Accounting (#602): record the fail-closed loop as positive safety
  # evidence. Advisory — a recording failure never alters this fallback.
  # When this invocation's loop is ALREADY in the log (recorded before the
  # posting step, e.g. head drift inside post_review), amend that line
  # instead of appending a duplicate fail-closed loop (#615 Codex).
  if p4b_acct_on 2>/dev/null; then
    if [ "${P4B_ACCT_LOOP_RECORDED:-false}" = true ]; then
      p4b_acct_mark_unposted "$why"
    else
      p4b_acct_hook_note_fallback "$why" \
        || p4b_warn "accounting: could not record the fail-closed loop (continuing)"
    fi
  fi
  if [ -x "$HANDOFF" ]; then
    PHASE_4B_REVIEWER_IDENTITY="$REVIEWER" "$HANDOFF" "$handoff_ref" >&2 2>/dev/null \
      || p4b_warn "could not render chat-side handoff block (needs gh); brief the human manually"
  fi
  jq -n --argjson pr "$PR" --arg repo "$REPO" --arg head "${HEAD:-}" \
        --arg direction "$DIRECTION" --arg reviewer "$REVIEWER" \
        --arg adapter "$ADAPTER" --arg why "$why" '
    {pr_number:$pr, repo:$repo, head_sha:$head, direction:$direction,
     reviewer_identity:$reviewer, adapter:$adapter, verdict:null,
     review_posted:false, fell_back_to_manual:true, reason:$why}'
  exit 4
}

# Temp hygiene: one EXIT trap owns every temp path this run creates (the
# review body rendered below and the dry-run accounting sandbox, when one
# exists).
_p4b_cleanup_tmp() {
  if [ -n "${BODY_FILE:-}" ]; then rm -f "$BODY_FILE" 2>/dev/null || true; fi
  if [ -n "${_P4B_ACCT_DRY_STATE:-}" ]; then rm -rf "$_P4B_ACCT_DRY_STATE" 2>/dev/null || true; fi
}
trap _p4b_cleanup_tmp EXIT

# Dry-run accounting isolation (#615 Codex round 11, P2): a dry-run must not
# mutate persistent accounting state. It used to append its simulated loop to
# the REAL per-PR loop log, where it was never rotated (no review posts on a
# dry-run) — so a later real run consumed rehearsal history: a dry-run
# CHANGES_REQUESTED P1 on the current head would trip the same-head safety
# gate against a subsequent valid approval, and a dry-run APPROVED loop
# inflated the next posted record's loop history and running totals. Redirect
# ALL accounting state (loop log, pending stage, ledger) to a throwaway COPY
# of the real state for the rest of this run: every hook — recording, render,
# rotation, the same-head gate — behaves exactly as a real run would (full
# history present, gate fidelity preserved), and the real state is untouched.
# Placed BEFORE the first fall_back_to_manual call site so even an early
# fallback's note_fallback recording lands in the sandbox.
_P4B_ACCT_DRY_STATE=""
if [ "$DRY_RUN" = true ] && [ "$P4B_ACCT_AVAILABLE" = true ]; then
  _p4b_real_state="$(p4b_acct_state_dir)"
  if _P4B_ACCT_DRY_STATE="$(mktemp -d "${TMPDIR:-/tmp}/p4b-acct-dry.XXXXXX" 2>/dev/null)"; then
    if [ -d "$_p4b_real_state" ]; then
      cp -Rp "$_p4b_real_state/." "$_P4B_ACCT_DRY_STATE/" 2>/dev/null \
        || p4b_warn "accounting: could not copy state into the dry-run sandbox; the dry-run renders from empty history (real state untouched)"
    fi
  else
    # No sandbox ⇒ still never touch real state: point at a fresh unused
    # path; hooks mkdir/append there or degrade advisorily (warn + plain
    # summary). Real state stays untouched either way.
    _P4B_ACCT_DRY_STATE="${TMPDIR:-/tmp}/p4b-acct-dry-unavailable.$$"
    p4b_warn "accounting: could not create the dry-run sandbox; dry-run accounting starts from empty state (real state untouched)"
  fi
  P4B_ACCT_STATE_DIR="$_P4B_ACCT_DRY_STATE"
  export P4B_ACCT_STATE_DIR
fi

if [ ! -x "$ADAPTER_SCRIPT" ]; then
  fall_back_to_manual "no adapter for reviewer '$REVIEWER' (expected $ADAPTER_SCRIPT)"
fi

# --- run the adapter (reasoning plane; never posts) ------------------------
ADAPTER_ARGS=( --pr "$PR" )
[ -n "$REPO" ]      && ADAPTER_ARGS+=( --repo "$REPO" )
[ -n "$HEAD" ]      && ADAPTER_ARGS+=( --head "$HEAD" )
[ -n "$DIFF_FILE" ] && ADAPTER_ARGS+=( --diff-file "$DIFF_FILE" )

# Accounting (#602): per-loop timing signals, captured whether or not the
# adapter succeeds so fail-closed loops carry their duration too.
P4B_ACCT_LOOP_STARTED_EPOCH="$(date +%s)"
set +e
VERDICT_JSON="$(p4b_run_with_timeout "$ADAPTER_TIMEOUT" "$ADAPTER_SCRIPT" "${ADAPTER_ARGS[@]}")"
ADAPTER_RC=$?
set -e
P4B_ACCT_LOOP_ELAPSED_SECONDS=$(( $(date +%s) - P4B_ACCT_LOOP_STARTED_EPOCH ))
export P4B_ACCT_LOOP_STARTED_EPOCH P4B_ACCT_LOOP_ELAPSED_SECONDS
if [ "$ADAPTER_RC" -ne 0 ]; then
  if p4b_is_timeout_rc "$ADAPTER_RC"; then
    fall_back_to_manual "adapter timed out after ${ADAPTER_TIMEOUT}s"
  fi
  fall_back_to_manual "adapter exited $ADAPTER_RC"
fi
# Defense in depth: re-validate before we act on it.
if ! p4b_validate_verdict "$VERDICT_JSON"; then
  fall_back_to_manual "adapter returned a non-conformant verdict"
fi

VERDICT="$(printf '%s' "$VERDICT_JSON" | jq -r '.verdict')"
SUMMARY="$(printf '%s' "$VERDICT_JSON" | jq -r '.summary')"
FINDINGS_COUNT="$(printf '%s' "$VERDICT_JSON" | jq -r '.findings | length')"
TOKEN_COUNT="$(printf '%s' "$VERDICT_JSON" | jq -r '.usage.token_count // empty')"
USAGE_SOURCE="$(printf '%s' "$VERDICT_JSON" | jq -r '.usage.source // empty')"
ADAPTER_RUNS=1

# p4b_file_post_review_issues <verdict-json>
# Policy step 9 executor (#672): one `post-review` + `observation` issue per
# discretionary finding on an APPROVED verdict, filed in $REPO under the
# AUTHOR identity and assigned to it. Writes go through gh-as-author.sh —
# the wrapper resolves the author PAT (OP_PREFLIGHT_AUTHOR_PAT or keyring)
# AND identity-verifies it before the write, which both satisfies the
# no-bare-gh-writes contract and closes the wrong-identity risk from the
# round-2 finding more strongly than manual token resolution did.
# Prints TWO lines: line 1 = comma-separated `#N` references (reused +
# created, for the review body), line 2 = the subset CREATED by this
# invocation (for cleanup — a reused prior-run issue must never be closed
# by this run's failure paths, #674 round-5 P2). ANY single failure —
# wrapper/token verification, a missing label on the target repo, an API
# error, or a DEDUP SEARCH error (#674 CodeRabbit Major: a swallowed search
# failure would read as "no existing issue" and mint duplicates) — returns
# non-zero so the caller refuses the approval (fail-closed: an APPROVED may
# never post with its observations unfiled; that failure mode degrades
# exactly to the pre-#672 refusal).
p4b_file_post_review_issues() {
  local vjson="$1" author_login refs="" created="" i total sev fpath fline fbody title bfile url existing
  author_login="$(p4b_top_field author_identity)"; author_login="${author_login:-nathanjohnpayne}"
  total="$(printf '%s' "$vjson" | jq -r '.findings | length')"
  i=0
  while [ "$i" -lt "$total" ]; do
    sev="$(printf '%s' "$vjson" | jq -r --argjson i "$i" '.findings[$i].severity')"
    fpath="$(printf '%s' "$vjson" | jq -r --argjson i "$i" '.findings[$i].path // "PR"')"
    fline="$(printf '%s' "$vjson" | jq -r --argjson i "$i" '.findings[$i].line // empty')"
    fbody="$(printf '%s' "$vjson" | jq -r --argjson i "$i" '.findings[$i].body')"
    # Policy step 9 labels are `post-review` plus `observation` OR `risk`
    # (#674 Codex P2): the verdict schema carries no risk flag, so classify
    # by the reviewer's own wording — a finding that talks about risk files
    # as one. Mislabels are trivially editable after the fact; the load-
    # bearing part is that risk follow-ups stay visible to `risk`-keyed
    # triage instead of being hard-coded observations.
    kind="observation"
    if printf '%s' "$fbody" | grep -qiE '(^|[^[:alpha:]])risk(s|y)?([^[:alpha:]]|$)'; then
      kind="risk"
    fi
    # Rerun idempotency (#674 CodeRabbit): a mid-loop failure leaves earlier
    # issues behind, and a straight rerun of the same verdict would file
    # them again. Every issue body embeds a stable head-pinned marker, and
    # the loop reuses a marker match instead of re-creating. Search-index
    # lag can miss a JUST-created issue; the worst case is one duplicate —
    # exactly the pre-marker status quo — never a lost filing. The marker
    # keys on a CONTENT fingerprint, not the array index (#674 round-3 P2):
    # a rerun that returns the same findings reordered or reworded must not
    # bind an old issue to whatever now occupies the same slot — changed
    # content mints a fresh issue (the superseded one stays open and
    # visible, never silently rebound).
    fp="$(printf '%s|%s|%s|%s' "$sev" "$fpath" "$fline" "$fbody" | cksum | cut -d' ' -f1)"
    marker="p4b-post-review ${REPO}#${PR} head=${HEAD:-unknown} finding=${fp}"
    if ! existing="$(gh search issues --repo "$REPO" --state open "\"$marker\"" --json url --jq '.[0].url // empty' 2>/dev/null)"; then
      # Dedup search ERROR ≠ dedup search EMPTY (#674 CodeRabbit Major):
      # an API/auth/rate-limit failure here must not read as "no existing
      # issue" and mint duplicates — fail closed like any other step.
      p4b_warn "post-review dedup search failed for fingerprint ${fp} — failing closed rather than risking duplicate issues"
      printf '%s\n%s' "$refs" "$created"
      return 1
    fi
    if [ -n "$existing" ]; then
      refs="${refs:+$refs, }#${existing##*/}"
      i=$((i + 1))
      continue
    fi
    # Title follows the documented step-9 convention (`[Post-Review] {brief
    # description}`, REVIEW_POLICY.md § post-merge issue creation — #674
    # round-3 P2) so title-shape triage and searches see auto-filed
    # follow-ups exactly like manual ones.
    title="$(printf '%.120s' "[Post-Review] ${kind} from ${REPO}#${PR}: ${sev} ${fpath}${fline:+:$fline}")"
    bfile="$(mktemp "${TMPDIR:-/tmp}/p4b-issue.XXXXXX")"
    {
      printf 'Advisory %s %s flagged by the automated Phase 4b APPROVED review of %s#%s. Filed by scripts/phase-4b-review.sh BEFORE the approval posted (policy step 9, #672).\n\n' "$sev" "$kind" "$REPO" "$PR"
      printf 'Anchor: `%s`%s\n\n' "$fpath" "${fline:+ line $fline}"
      printf '%s\n' "$fbody"
      printf '\nReviewer: %s (%s adapter). Reviewed head: `%s`.\n' "$REVIEWER" "$ADAPTER" "${HEAD:-unknown}"
      printf '\n<!-- %s -->\n' "$marker"
    } > "$bfile"
    url="$("$GH_AS_AUTHOR" -- gh issue create --repo "$REPO" \
      --title "$title" --body-file "$bfile" \
      --label post-review --label "$kind" \
      --assignee "$author_login" 2>/dev/null)" \
      || { rm -f "$bfile"; printf '%s\n%s' "$refs" "$created"; return 1; }
    rm -f "$bfile"
    [ -n "$url" ] || { printf '%s\n%s' "$refs" "$created"; return 1; }
    refs="${refs:+$refs, }#${url##*/}"
    created="${created:+$created, }#${url##*/}"
    i=$((i + 1))
  done
  printf '%s\n%s' "$refs" "$created"
}

# p4b_close_post_review_issues <refs "#1, #2"> <reason>
# Self-cleanup for the filing side effect (#674 round-4 P2): when an
# approval is refused AFTER issues were filed (head drift, partial filing
# failure), the filed issues are closed as superseded rather than left
# orphaned — the dedup search is open-state-scoped, so a rerun files fresh
# follow-ups instead of resurrecting closed refs. Best-effort: a close
# failure warns with the ref so the operator can close manually; it never
# changes the refusal outcome.
p4b_close_post_review_issues() {
  local refs="$1" reason="$2" n
  for n in $(printf '%s' "$refs" | tr ',' ' '); do
    n="${n##*#}"
    [ -n "$n" ] || continue
    "$GH_AS_AUTHOR" -- gh issue close "$n" --repo "$REPO" --comment "$reason" >/dev/null 2>&1 \
      || p4b_warn "could not close superseded post-review issue #$n — close it manually"
  done
  return 0
}

POST_REVIEW_ISSUE_REFS=""
P4B_CREATED_ISSUE_REFS=""
if [ "$VERDICT" = "APPROVED" ] && [ "$FINDINGS_COUNT" -gt 0 ]; then
  # Policy step 9 (#672): observations/risks from an approving external
  # reviewer become post-review issues BEFORE the approval clears the merge
  # gate. The validator has already rejected APPROVED carrying any
  # policy-REQUIRED tier, so every finding here is discretionary — file the
  # issues mechanically and post the APPROVED with the references, instead
  # of discarding the verdict into the manual handoff (which stranded the
  # caller without the findings it needed to comply). Opt out with
  # phase_4b_automation.post_review_issues: false (restores the pre-#672
  # refusal); dry-run prints intent and files nothing.
  # Opt-out is validated fail-closed (#674 CodeRabbit): only the literal
  # true/false (or absent ⇒ true) are accepted — a typo like `False`, `no`,
  # or `0` must not silently fail OPEN into auto-filing issues under the
  # author PAT.
  _pri_knob="$(p4b_automation_field post_review_issues)"
  case "${_pri_knob:-true}" in
    true) : ;;
    false)
      fall_back_to_manual "approved verdict included findings and phase_4b_automation.post_review_issues is false; post-review issue filing is required before Phase 4b clearance"
      ;;
    *)
      fall_back_to_manual "invalid phase_4b_automation.post_review_issues value '${_pri_knob}' (expected true or false) — refusing fail-closed"
      ;;
  esac
  # Tiers the feedback policy marks `ignore` are never surfaced (#674 Codex
  # P2): drop them from the FILE set. The review body still lists every
  # verdict finding — it is the faithful record of what the reviewer said —
  # but no follow-up issue is opened for suppressed tiers.
  IGNORED_SEVS='[]'; _ig_first=true
  for _tier in p0 p1 p2 p3; do
    if [ "$(p4b_feedback_priority_value "$_tier")" = "ignore" ]; then
      if [ "$_ig_first" = true ]; then IGNORED_SEVS='['; _ig_first=false; else IGNORED_SEVS="$IGNORED_SEVS,"; fi
      IGNORED_SEVS="$IGNORED_SEVS\"$(printf '%s' "$_tier" | tr '[:lower:]' '[:upper:]')\""
    fi
  done
  [ "$_ig_first" = true ] || IGNORED_SEVS="$IGNORED_SEVS]"
  FILE_JSON="$(printf '%s' "$VERDICT_JSON" | jq -c --argjson ig "$IGNORED_SEVS" \
    '{findings: [.findings[] | . as $f | select(($ig | index($f.severity)) | not)]}')"
  FILE_COUNT="$(printf '%s' "$FILE_JSON" | jq -r '.findings | length')"
  if [ "$FILE_COUNT" -eq 0 ]; then
    p4b_log "all $FINDINGS_COUNT APPROVED finding(s) fall in feedback_policy ignore tiers — never surfaced, nothing to file"
  elif [ "$DRY_RUN" = true ]; then
    p4b_log "[dry-run] would file $FILE_COUNT post-review issue(s) in $REPO ($FINDINGS_COUNT finding(s) total; ignored tiers filtered), then post APPROVED with the references"
    POST_REVIEW_ISSUE_REFS="(dry-run: $FILE_COUNT issue(s) would be filed)"
  else
    # Side-effect ordering (#674 Codex P2): re-read the live head BEFORE
    # filing anything. post_review re-checks again at POST time, but by
    # then the issues would already exist — a head that drifted during the
    # adapter run must refuse here, with zero issues claiming an approval
    # that will never post.
    live_head_pre="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)"
    [ -n "$live_head_pre" ] \
      || fall_back_to_manual "could not re-read the live PR head before filing post-review issues"
    if [ "$live_head_pre" != "$HEAD" ]; then
      fall_back_to_manual "PR head changed during review (reviewed $HEAD, live $live_head_pre) — refusing to file post-review issues for an approval that will not post"
    fi
    # Same-head laundering gate, hoisted ahead of the side effects (#674
    # Codex round-2 P2): the authoritative gate below still guards the
    # POST, but by then the issues would already exist for an approval
    # that gets refused. Same guards as the authoritative copy (module
    # loaded; hook consults the loop log keyed to the current HEAD).
    if [ "$P4B_ACCT_AVAILABLE" = true ] && ! p4b_acct_hook_same_head_required_block; then
      fall_back_to_manual "an unresolved required-tier finding was recorded on the current head ($HEAD) in a prior Phase 4b loop — refusing to file post-review issues for an approval that will not post"
    fi
    set +e
    _pri_out="$(p4b_file_post_review_issues "$FILE_JSON")"
    _pri_rc=$?
    set -e
    POST_REVIEW_ISSUE_REFS="$(printf '%s\n' "$_pri_out" | sed -n 1p)"
    # Cleanup operates ONLY on refs this invocation created (#674 round-5
    # P2): a reused prior-run issue in the body refs must never be closed
    # because a later step of THIS run failed.
    P4B_CREATED_ISSUE_REFS="$(printf '%s\n' "$_pri_out" | sed -n 2p)"
    if [ "$_pri_rc" -ne 0 ]; then
      # Partial-failure orphans (#674 round-2 + round-4 P2s): surface any
      # refs that DID file, close this run's creations as superseded
      # (self-cleanup), and refuse. The dedup search is open-scoped, so a
      # rerun files fresh follow-ups instead of resurrecting the closed
      # ones.
      if [ -n "$P4B_CREATED_ISSUE_REFS" ]; then
        p4b_warn "post-review issue filing failed partway; closing this run's created refs as superseded: $P4B_CREATED_ISSUE_REFS"
        p4b_close_post_review_issues "$P4B_CREATED_ISSUE_REFS" "Superseded: post-review filing for ${REPO}#${PR} failed partway and the Phase 4b approval was refused; a rerun files fresh follow-ups."
      fi
      fall_back_to_manual "approved verdict included findings and post-review issue filing failed${POST_REVIEW_ISSUE_REFS:+ (partial refs: $POST_REVIEW_ISSUE_REFS, created subset closed as superseded)}; refusing to post an approval with unfiled observations"
    fi
    [ -n "$POST_REVIEW_ISSUE_REFS" ] \
      || fall_back_to_manual "approved verdict included findings but post-review issue filing produced no references"
    # Post-file head recheck (#674 round-4 P2): a head that drifted DURING
    # filing pins the just-filed issues to a head whose approval will be
    # refused at post_review, and a new-head rerun cannot reuse the old
    # head-pinned markers. Close this run's creations and refuse now.
    live_head_post="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)"
    if [ -z "$live_head_post" ] || [ "$live_head_post" != "$HEAD" ]; then
      p4b_warn "PR head drifted during issue filing (reviewed $HEAD, live ${live_head_post:-unreadable}) — closing this run's filed issues as superseded"
      p4b_close_post_review_issues "$P4B_CREATED_ISSUE_REFS" "Superseded: the PR head of ${REPO}#${PR} changed before the Phase 4b approval could post; a re-run on the new head files fresh follow-ups."
      fall_back_to_manual "PR head changed while filing post-review issues (reviewed $HEAD, live ${live_head_post:-unreadable}); the filed issues were closed as superseded"
    fi
    p4b_log "filed $FILE_COUNT post-review issue(s): $POST_REVIEW_ISSUE_REFS"
    # Enrich the accounting record (#675): the line-1 refs align 1:1 with
    # FILE_JSON.findings (reused + created alike, in filing order). Zip them
    # into the tuple-keyed filed-issues channel accounting.sh joins in
    # p4b_acct_unique_findings, flipping each filed finding's record entry from
    # unresolved/null to disposition "deferred-to-follow-up" + its issue link
    # (advisory_issues_filed then derives), so the machine-readable record
    # matches the prose "filed as #N" reference instead of contradicting it.
    # Built via p4b_acct_filed_issues_from_refs (numeric, position-preserving
    # parse — a malformed middle ref never shifts a later issue onto the wrong
    # finding, #675 Codex round 1), and ONLY when accounting is loaded (its sole
    # consumer). Exported BEFORE the accounting render block reads it.
    if [ "$P4B_ACCT_AVAILABLE" = true ]; then
      P4B_ACCT_FILED_ISSUES_JSON="$(p4b_acct_filed_issues_from_refs "$POST_REVIEW_ISSUE_REFS" "$FILE_JSON")"
      [ -n "$P4B_ACCT_FILED_ISSUES_JSON" ] || P4B_ACCT_FILED_ISSUES_JSON='[]'
      export P4B_ACCT_FILED_ISSUES_JSON
    fi
  fi
fi

# Render the PR review body (summary + findings list).
BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/p4b-body.XXXXXX")"
# (cleanup is owned by the _p4b_cleanup_tmp EXIT trap installed above)
{
  printf '**Automated Phase 4b review** (%s, reviewer %s)\n\n' "$DIRECTION" "$REVIEWER"
  printf '%s\n' "$SUMMARY"
  printf '\n### Review Metadata\n\n'
  printf -- '- Reviewed head: `%s`\n' "${HEAD:-unknown}"
  printf -- '- Reviewer identity: `%s`\n' "$REVIEWER"
  printf -- '- Adapter: `%s`\n' "$ADAPTER"
  printf -- '- Adapter runs: `%s`\n' "$ADAPTER_RUNS"
  printf -- '- Adapter timeout: `%ss`\n' "$ADAPTER_TIMEOUT"
  printf -- '- Reviewer effort: `%s`\n' "${EFFECTIVE_EFFORT:-cli-default}"
  if [ -n "$TOKEN_COUNT" ]; then
    printf -- '- Token usage: `%s` tokens' "$TOKEN_COUNT"
    [ -n "$USAGE_SOURCE" ] && printf ' (source: `%s`)' "$USAGE_SOURCE"
    printf '\n'
  else
    printf -- '- Token usage: not exposed by adapter/CLI\n'
  fi
  printf -- '- Model-internal turn count: not exposed by the adapter contract\n'
  if [ "$FINDINGS_COUNT" -gt 0 ]; then
    printf '\n### Findings\n\n'
    printf '%s' "$VERDICT_JSON" | jq -r '
      .findings[]
      | "- **\(.severity)** \((.path // "PR") + (if .line then ":\(.line)" else "" end)): \(.body)"'
    if [ "$VERDICT" = "APPROVED" ]; then
      # Accurate audit trail (#674 round-3 P3): only claim filing for the
      # subset that actually filed; ignored-tier findings are listed above
      # as the faithful verdict record but are deliberately not surfaced
      # as issues.
      _ign_count=$(( FINDINGS_COUNT - ${FILE_COUNT:-$FINDINGS_COUNT} ))
      if [ -n "$POST_REVIEW_ISSUE_REFS" ] && [ "$_ign_count" -eq 0 ]; then
        printf '\nEach finding above is an advisory follow-up filed as a post-review issue before this approval posted (policy step 9, #672): %s\n' "$POST_REVIEW_ISSUE_REFS"
      elif [ -n "$POST_REVIEW_ISSUE_REFS" ]; then
        printf '\n%s of the findings above were filed as post-review issues before this approval posted (policy step 9, #672): %s. The other %s fall in feedback_policy ignore tiers and were deliberately not surfaced as issues.\n' "${FILE_COUNT:-0}" "$POST_REVIEW_ISSUE_REFS" "$_ign_count"
      elif [ "$_ign_count" -gt 0 ]; then
        printf '\nAll %s finding(s) above fall in feedback_policy ignore tiers — listed as the faithful verdict record, deliberately not surfaced as post-review issues.\n' "$_ign_count"
      fi
    fi
  fi
  printf '\n\n_Posted by scripts/phase-4b-review.sh under the reviewer identity. See plans/automated-phase-4b-handoff.md._\n'
} > "$BODY_FILE"

# --- Phase 4b approval-loop accounting (#602) --------------------------------
# Advisory to safety: any failure below leaves BODY_FILE as the plain summary
# above and never changes review posting or exit codes. Gated on
# phase_4b_automation.accounting.enabled (default true under the disabled
# parent). Loop records accumulate across invocations in the per-PR loop log
# so a CHANGES_REQUESTED → fix → APPROVED cycle renders its full history.
if p4b_acct_on 2>/dev/null; then
  # Clear any stale pending ledger record from a prior run that crashed after
  # staging but before posting (#615 Codex round 6). Without this, an APPROVED
  # run whose accounting render later fails/skips (the fail-open path) never
  # re-stages, and the two-phase commit would append that phantom/old record
  # after the new review posts. The render below re-stages a freshly tagged
  # record on the happy path; the commit-time run-id check is the belt to this
  # suspenders. Advisory — never alters review flow.
  p4b_acct_hook_discard_pending_record || true
  ACCT_POSTED_STATE="posted"
  [ "$DRY_RUN" = true ] && ACCT_POSTED_STATE="dry-run"
  # The loop is recorded (and the block rendered) BEFORE post_review so the
  # posted body can include this loop; the posted claim is provisional until
  # the POST succeeds — every non-posting exit path below corrects it via
  # p4b_acct_mark_unposted, and the ledger record is staged, committed only
  # after a successful POST (#615 Codex: no phantom posted approvals).
  if p4b_acct_hook_record_loop "$VERDICT" "$ACCT_POSTED_STATE" false ""; then
    P4B_ACCT_LOOP_RECORDED=true
  else
    p4b_warn "accounting: could not record this loop (plain summary unaffected)"
  fi
  # Render the accounting block ONLY when THIS invocation's loop was recorded
  # (#615 Codex round 5). p4b_acct_hook_render_approval_block builds the block
  # from the loop log; if recording the current loop failed (e.g. a read-only
  # loop-log), the log still holds this PR's OLDER loops, and rendering from it
  # would emit a block stamped with the CURRENT head whose rigor table claims
  # that head was reviewed while SILENTLY omitting the current loop — corrupted
  # accounting instead of an honest fallback. Skipping the render here posts the
  # plain-summary approval (accounting is advisory; the approval is never
  # blocked). A recorded-but-otherwise-degraded render still fails-open below.
  if [ "$VERDICT" = "APPROVED" ] && [ "${P4B_ACCT_LOOP_RECORDED:-false}" = true ]; then
    if ACCT_BLOCK="$(p4b_acct_hook_render_approval_block)" && [ -n "$ACCT_BLOCK" ]; then
      # Size guard (#615 Codex round 8, finding 1): the appended block becomes
      # part of the ONLY body POSTed to GitHub, whose review body has a hard
      # ~65536-char cap. A large accounting block (many loops/findings) could
      # push the combined body past that cap and make the APPROVE POST fail —
      # letting advisory accounting block a valid clearance. Accounting must
      # never do that. If appending the block would exceed the safe budget
      # (default 60000, leaving GitHub headroom over the plain summary), the
      # block is TRUNCATED with an explicit notice; if even the notice would
      # not fit, the block is dropped and the plain-summary approval posts.
      # Configurable via P4B_ACCT_MAX_BODY_BYTES (0 disables the guard).
      _p4b_acct_max_body="${P4B_ACCT_MAX_BODY_BYTES:-60000}"
      case "$_p4b_acct_max_body" in ''|*[!0-9]*) _p4b_acct_max_body=60000 ;; esac
      _p4b_acct_notice='

_[accounting truncated: the full block would exceed the review-body size limit; running totals and the machine-readable record are omitted here to keep this valid approval postable. See the per-checkout ledger / prior approvals for complete accounting.]_'
      if [ "$_p4b_acct_max_body" -gt 0 ]; then
        _p4b_acct_base_bytes="$(wc -c < "$BODY_FILE" 2>/dev/null | tr -d '[:space:]')"
        case "$_p4b_acct_base_bytes" in ''|*[!0-9]*) _p4b_acct_base_bytes=0 ;; esac
        # The append writes "\n\n" (2) + `printf '%s\n' "$ACCT_BLOCK"`. Measure a
        # candidate append as base + 2 + bytes-of(printf '%s\n' block), so every
        # size decision uses the SAME accounting (no off-by-one drift).
        _p4b_acct_appended_bytes() { # <candidate-block> -> total posted body bytes
          local blk="$1" n
          n="$(printf '%s\n' "$blk" | wc -c 2>/dev/null | tr -d '[:space:]')"
          case "$n" in ''|*[!0-9]*) n=0 ;; esac
          printf '%s' "$(( _p4b_acct_base_bytes + 2 + n ))"
        }
        if [ "$(_p4b_acct_appended_bytes "$ACCT_BLOCK")" -gt "$_p4b_acct_max_body" ]; then
          # Budget for the block CONTENT prefix we keep, leaving room for the
          # "\n\n" separator, the notice, and printf's trailing "\n".
          _p4b_acct_notice_bytes="$(printf '%s' "$_p4b_acct_notice" | wc -c 2>/dev/null | tr -d '[:space:]')"
          case "$_p4b_acct_notice_bytes" in ''|*[!0-9]*) _p4b_acct_notice_bytes=0 ;; esac
          # -8 safety margin absorbs a multibyte cut at the truncation boundary
          # so the final body lands comfortably under the cap (no belt trigger).
          _p4b_acct_keep=$(( _p4b_acct_max_body - _p4b_acct_base_bytes - 2 - _p4b_acct_notice_bytes - 1 - 8 ))
          if [ "$_p4b_acct_keep" -gt 0 ]; then
            # SIGPIPE-safe truncation (#615 Codex round 9, finding 1): the prior
            # `printf … | head -c` form aborts the whole orchestrator under
            # `set -euo pipefail`. For a block larger than the pipe buffer, head
            # -c closes the pipe after reading its prefix and printf gets SIGPIPE
            # (exit 141); pipefail then fails the command substitution and, under
            # set -e, exits the script BEFORE post_review — advisory accounting
            # would block a valid approval, the exact opposite of the guard's
            # intent. Use a pure-bash byte substring (no pipe, no producer to
            # signal). `LC_ALL=C` makes `${var:0:N}` count BYTES (default UTF-8
            # locale counts characters), so the slice honors the byte budget and
            # the -8 margin still absorbs a mid-multibyte cut; the belt below
            # re-measures and drops the block if a cut still overshoots.
            # Marker-safe cut (#615 Codex round 10, P3): a raw byte-prefix cut
            # can land INSIDE the embedded `<!-- p4b-accounting:v1 ... -->`
            # record, leaving an unterminated HTML comment that swallows the
            # visible truncation notice appended below. The helper backs the
            # cut off to just before the comment-open marker in that case.
            _p4b_acct_trunc="$(p4b_acct_safe_truncate "$ACCT_BLOCK" "$_p4b_acct_keep")"
            ACCT_BLOCK="${_p4b_acct_trunc}${_p4b_acct_notice}"
            p4b_warn "accounting: block exceeds the review-body size budget ($_p4b_acct_max_body bytes); truncating it so the approval still posts"
          else
            ACCT_BLOCK=""
            p4b_warn "accounting: no room for the accounting block within the review-body size budget; posting the plain-summary approval"
          fi
          # Belt-and-suspenders: if a multibyte cut left the candidate still over
          # the cap, drop the block entirely rather than risk a POST-rejecting
          # body. The approval is never blocked either way.
          if [ -n "$ACCT_BLOCK" ] \
             && [ "$(_p4b_acct_appended_bytes "$ACCT_BLOCK")" -gt "$_p4b_acct_max_body" ]; then
            ACCT_BLOCK=""
            p4b_warn "accounting: truncated block still exceeded the body budget; dropping it and posting the plain-summary approval"
          fi
        fi
      fi
      if [ -n "$ACCT_BLOCK" ]; then
        if ! { printf '\n\n'; printf '%s\n' "$ACCT_BLOCK"; } >> "$BODY_FILE"; then
          p4b_warn "accounting: could not append the accounting block; posting the plain-summary approval"
        fi
      fi
    else
      p4b_warn "accounting: report generation failed; posting the plain-summary approval (never blocks a valid approval)"
    fi
  elif [ "$VERDICT" = "APPROVED" ]; then
    p4b_warn "accounting: current loop was not recorded; skipping the accounting block so the posted approval never omits this loop while stamping the current head (plain summary posts)"
  fi

fi

# --- Same-head required-finding SAFETY gate (#615 Codex round 9, finding 2) --
# Unlike the accounting BLOCK above (advisory — its failure never blocks a
# valid approval), this is a fail-closed SAFETY check on the approval itself.
# The fail-closed invariant (an APPROVED verdict may never carry an unresolved
# required-tier finding on the CURRENT head) lived only inside the accounting
# RECORD builder: a same-head laundered approval made p4b_acct_build_record
# return non-zero, the render hook propagated that as an ordinary advisory
# report-generation failure, and the orchestrator posted the plain-summary
# APPROVED anyway — letting a P0/P1 CHANGES_REQUESTED on head `abc` be
# laundered into a clean approval by rerunning the reviewer on the SAME head
# with no fix commit. Here we run the SAME assertion against the live loop log
# keyed to the current HEAD, in same_head_only mode (#615 round 9 CodeRabbit:
# the current loop is legitimately ABSENT from the log whenever recording
# failed or accounting is disabled, so the record-scoped clauses must not
# apply); when it refuses, the approval is REFUSED via the manual handoff
# (fall_back_to_manual, exit 4), never posted. A head change (a real fix
# commit) or a fail-closed-marked prior loop clears it — the assertion permits
# the legitimate changes-requested-then-fixed path.
#
# Placement (#615 Codex round 10): this gate sits OUTSIDE the p4b_acct_on
# sub-toggle block above, guarded on P4B_ACCT_AVAILABLE (module loaded) alone.
# Inside that block, opting out via phase_4b_automation.accounting.enabled:
# false AFTER a prior loop logged a required finding on this head would skip
# the gate and launder the finding through a same-head rerun. Out here the
# toggle only stops NEW recording; history already on disk still blocks. Gate
# is a no-op when the verdict is not APPROVED, when there is no
# readable/parseable loop log, or when the module never loaded
# (P4B_ACCT_AVAILABLE=false: nothing ever recorded history, so there is no
# history to launder — and the hook function does not exist, so a bare call
# would exit 127 into fall_back_to_manual and refuse every valid approval the
# module-missing contract at the top of this file says must post plain; #615
# round 9, CodeRabbit).
if [ "$VERDICT" = "APPROVED" ] \
   && [ "$P4B_ACCT_AVAILABLE" = true ] \
   && ! p4b_acct_hook_same_head_required_block; then
  fall_back_to_manual "an unresolved required-tier finding was recorded on the current head ($HEAD) in a prior Phase 4b loop; a rerun without a fix commit cannot launder it into a clean approval (fail-closed)"
fi

# --- map verdict -> GitHub review state ------------------------------------
post_review() {
  local state_flag="$1"
  local gh_bin=gh
  local api_cmd=api
  local event payload_file review_response review_rc created_commit
  [ -x "$GH_AS_REVIEWER" ] || { p4b_acct_mark_unposted "gh-as-reviewer.sh not found"; p4b_die 3 "gh-as-reviewer.sh not found at $GH_AS_REVIEWER"; }
  command -v gh >/dev/null 2>&1 || { p4b_acct_mark_unposted "gh unavailable for review POST"; p4b_die 3 "gh is required to post the review"; }
  case "$state_flag" in
    --approve) event="APPROVE" ;;
    --request-changes) event="REQUEST_CHANGES" ;;
    *) p4b_die 3 "unsupported review state flag: $state_flag" ;;
  esac
  local live_head
  live_head="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)"
  [ -n "$live_head" ] || { p4b_acct_mark_unposted "could not re-read live PR head before posting review"; p4b_die 3 "could not re-read live PR head before posting review"; }
  if [ "$live_head" != "$HEAD" ]; then
    # Late-window drift (#674 round-5 P2): a push landing during body or
    # accounting rendering reaches this final check with the step-9 issues
    # already filed — close this run's creations before refusing, same as
    # the post-file recheck, so no orphan claims an approval that never
    # posted.
    if [ "$event" = "APPROVE" ] && [ -n "${P4B_CREATED_ISSUE_REFS:-}" ]; then
      p4b_warn "PR head drifted before the approval POST — closing this run's filed post-review issues as superseded: $P4B_CREATED_ISSUE_REFS"
      p4b_close_post_review_issues "$P4B_CREATED_ISSUE_REFS" "Superseded: the PR head of ${REPO}#${PR} changed before the Phase 4b approval could post; a re-run on the new head files fresh follow-ups."
    fi
    fall_back_to_manual "PR head changed during review (reviewed $HEAD, live $live_head)"
  fi
  payload_file="$(mktemp "${TMPDIR:-/tmp}/p4b-review-payload.XXXXXX")"
  jq -n --arg commit_id "$HEAD" --arg event "$event" --rawfile body "$BODY_FILE" \
    '{commit_id:$commit_id,event:$event,body:$body}' > "$payload_file"
  set +e
  review_response="$(
    env -u OP_PREFLIGHT_REVIEWER_PAT GH_AS_REVIEWER_IDENTITY="$REVIEWER" "$GH_AS_REVIEWER" -- \
      "$gh_bin" "$api_cmd" "repos/$REPO/pulls/$PR/reviews" --method POST --input "$payload_file"
  )"
  review_rc=$?
  set -e
  rm -f "$payload_file"
  [ "$review_rc" -eq 0 ] || { p4b_acct_mark_unposted "review POST failed (gh exit $review_rc)"; return "$review_rc"; }
  created_commit="$(printf '%s' "$review_response" | jq -r '.commit_id // empty' 2>/dev/null || true)"
  [ "$created_commit" = "$HEAD" ] || { p4b_acct_mark_unposted "created review not pinned to reviewed head"; p4b_die 3 "created review was not pinned to reviewed head (expected $HEAD, got ${created_commit:-unknown})"; }
}

REVIEW_POSTED=false
EXIT_CODE=0
case "$VERDICT" in
  APPROVED)
    if [ "$DRY_RUN" = true ]; then
      p4b_log "[dry-run] would post APPROVED as $REVIEWER on $REPO#$PR (HEAD ${HEAD:-?})"
    else
      post_review --approve || p4b_die 3 "failed to post APPROVED review"
      REVIEW_POSTED=true
      # Phase two of the accounting ledger commit (#615 Codex): the review is
      # confirmed on GitHub, so the staged record may now enter the ledger.
      if p4b_acct_on 2>/dev/null; then
        p4b_acct_hook_commit_posted_record || true
      fi
      p4b_log "posted APPROVED as $REVIEWER — Phase 4b substitute clearance is now on HEAD"
    fi
    EXIT_CODE=0
    ;;
  CHANGES_REQUESTED)
    if [ "$DRY_RUN" = true ]; then
      p4b_log "[dry-run] would post CHANGES_REQUESTED as $REVIEWER on $REPO#$PR"
    else
      post_review --request-changes || p4b_die 3 "failed to post CHANGES_REQUESTED review"
      REVIEW_POSTED=true
      p4b_log "posted CHANGES_REQUESTED as $REVIEWER — author addresses findings, then re-run"
    fi
    EXIT_CODE=1
    ;;
  *)
    fall_back_to_manual "unexpected verdict '$VERDICT' (schema should prevent this)"
    ;;
esac

# --- emit machine-readable summary -----------------------------------------
jq -n \
  --argjson pr "$PR" \
  --arg repo "$REPO" \
  --arg head "${HEAD:-}" \
  --arg direction "$DIRECTION" \
  --arg reviewer "$REVIEWER" \
  --arg adapter "$ADAPTER" \
  --arg verdict "$VERDICT" \
  --argjson review_posted "$REVIEW_POSTED" \
  --argjson dry_run "$DRY_RUN" \
  --arg token_count "${TOKEN_COUNT:-}" \
  --arg usage_source "$USAGE_SOURCE" \
  --argjson adapter_timeout "$ADAPTER_TIMEOUT" \
  --arg effort "$EFFECTIVE_EFFORT" \
  --argjson findings_count "$FINDINGS_COUNT" '
  {
    pr_number: $pr,
    repo: $repo,
    head_sha: $head,
    direction: $direction,
    reviewer_identity: $reviewer,
    adapter: $adapter,
    verdict: $verdict,
    review_posted: $review_posted,
    dry_run: $dry_run,
    findings_count: $findings_count,
    adapter_timeout_seconds: $adapter_timeout,
    reviewer_effort: (if $effort == "" then null else $effort end),
    token_count: (if $token_count == "" then null else ($token_count | tonumber) end),
    usage_source: (if $usage_source == "" then null else $usage_source end),
    fell_back_to_manual: false,
    automation_enabled: true
  }'

exit "$EXIT_CODE"
