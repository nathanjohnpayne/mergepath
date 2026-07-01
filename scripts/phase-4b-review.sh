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
#   P4B_HANDOFF                     manual handoff renderer override (tests).
#   P4B_ADAPTER_TIMEOUT_SECONDS     default: 900.
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

# Auto-source the op-preflight reviewer PAT when GH_TOKEN is unset (#282),
# mirroring the sibling helpers. Read-only-plus-one-review scope = reviewer.
if [ -r "$ROOT/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$ROOT/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
  load_preflight_env_vars
fi

ADAPTER_DIR="$ROOT/phase-4b/adapters"
HANDOFF="${P4B_HANDOFF:-$ROOT/post-phase-4b-handoff.sh}"
GH_AS_REVIEWER="${P4B_GH_AS_REVIEWER:-$ROOT/gh-as-reviewer.sh}"
ADAPTER_TIMEOUT="${P4B_ADAPTER_TIMEOUT_SECONDS:-900}"

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

p4b_log "PR $REPO#$PR  HEAD=${HEAD:-?}  direction=$DIRECTION  reviewer=$REVIEWER  adapter=$ADAPTER  dry_run=$DRY_RUN"

# --- manual-handoff fallback -----------------------------------------------
fall_back_to_manual() {
  local why="$1"
  local handoff_ref="$PR"
  [ -n "$REPO" ] && handoff_ref="${REPO}#${PR}"
  p4b_warn "falling back to the manual Phase 4b handoff: $why"
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

if [ ! -x "$ADAPTER_SCRIPT" ]; then
  fall_back_to_manual "no adapter for reviewer '$REVIEWER' (expected $ADAPTER_SCRIPT)"
fi

# --- run the adapter (reasoning plane; never posts) ------------------------
ADAPTER_ARGS=( --pr "$PR" )
[ -n "$REPO" ]      && ADAPTER_ARGS+=( --repo "$REPO" )
[ -n "$HEAD" ]      && ADAPTER_ARGS+=( --head "$HEAD" )
[ -n "$DIFF_FILE" ] && ADAPTER_ARGS+=( --diff-file "$DIFF_FILE" )

set +e
VERDICT_JSON="$(p4b_run_with_timeout "$ADAPTER_TIMEOUT" "$ADAPTER_SCRIPT" "${ADAPTER_ARGS[@]}")"
ADAPTER_RC=$?
set -e
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

if [ "$VERDICT" = "APPROVED" ] && [ "$FINDINGS_COUNT" -gt 0 ]; then
  fall_back_to_manual "approved verdict included findings; post-review issue filing is required before Phase 4b clearance"
fi

# Render the PR review body (summary + findings list).
BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/p4b-body.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$BODY_FILE'" EXIT
{
  printf '**Automated Phase 4b review** (%s, reviewer %s)\n\n' "$DIRECTION" "$REVIEWER"
  printf '%s\n' "$SUMMARY"
  printf '\n### Review Metadata\n\n'
  printf -- '- Reviewed head: `%s`\n' "${HEAD:-unknown}"
  printf -- '- Reviewer identity: `%s`\n' "$REVIEWER"
  printf -- '- Adapter: `%s`\n' "$ADAPTER"
  printf -- '- Adapter runs: `%s`\n' "$ADAPTER_RUNS"
  printf -- '- Adapter timeout: `%ss`\n' "$ADAPTER_TIMEOUT"
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
  fi
  printf '\n\n_Posted by scripts/phase-4b-review.sh under the reviewer identity. See plans/automated-phase-4b-handoff.md._\n'
} > "$BODY_FILE"

# --- map verdict -> GitHub review state ------------------------------------
post_review() {
  local state_flag="$1"
  local gh_bin=gh api_cmd=api event payload_file review_response review_rc created_commit
  [ -x "$GH_AS_REVIEWER" ] || p4b_die 3 "gh-as-reviewer.sh not found at $GH_AS_REVIEWER"
  command -v gh >/dev/null 2>&1 || p4b_die 3 "gh is required to post the review"
  case "$state_flag" in
    --approve) event="APPROVE" ;;
    --request-changes) event="REQUEST_CHANGES" ;;
    *) p4b_die 3 "unsupported review state flag: $state_flag" ;;
  esac
  local live_head
  live_head="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)"
  [ -n "$live_head" ] || p4b_die 3 "could not re-read live PR head before posting review"
  if [ "$live_head" != "$HEAD" ]; then
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
  [ "$review_rc" -eq 0 ] || return "$review_rc"
  created_commit="$(printf '%s' "$review_response" | jq -r '.commit_id // empty' 2>/dev/null || true)"
  [ "$created_commit" = "$HEAD" ] || p4b_die 3 "created review was not pinned to reviewed head (expected $HEAD, got ${created_commit:-unknown})"
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
    token_count: (if $token_count == "" then null else ($token_count | tonumber) end),
    usage_source: (if $usage_source == "" then null else $usage_source end),
    fell_back_to_manual: false,
    automation_enabled: true
  }'

exit "$EXIT_CODE"
