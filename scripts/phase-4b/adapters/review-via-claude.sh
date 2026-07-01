#!/usr/bin/env bash
# scripts/phase-4b/adapters/review-via-claude.sh
#
# Phase 4b reviewer adapter — Direction B (Codex -> Claude). Drives the
# Claude Code CLI in print/headless, read-only (plan) mode to review a PR
# diff and emit a normalized verdict object (verdict.schema.json) on stdout.
#
# REFERENCE IMPLEMENTATION. Reasoning only; it never posts to GitHub. The
# orchestrator posts the verdict under the reviewer PAT via
# scripts/gh-as-reviewer.sh.
#
# Design choice: Claude ships a built-in `/review` that reviews a GitHub PR
# and posts findings itself. We deliberately do NOT use `/review` here,
# because that would post under Claude's own GitHub auth and bypass the
# reviewer-PAT attribution wrapper. Instead we ask Claude (read-only, plan
# mode) to RETURN the structured verdict, and let the orchestrator post it.
#
# Docs (verbatim flags):
#   claude -p "<prompt>" --permission-mode plan --output-format json \
#     --allowedTools "Read,Bash(git diff *)"
#   https://code.claude.com/docs/en/headless
#   https://code.claude.com/docs/en/permission-modes
# The print-mode JSON envelope carries the model's answer in `.result`
# (confirm the exact field against the headless docs for your CLI version).
#
# Usage:
#   review-via-claude.sh --pr <N> --repo <owner/repo> [--head <sha>]
#                        [--diff-file <path>] [--model <m>]
#
# Env:
#   CLAUDE_BIN  claude executable (default: claude). Tests point this at a fake.
#   Claude Code plan login   reasoning-plane auth. This adapter requires
#               `claude auth status --json` to report apiProvider=firstParty
#               with authMethod=claude.ai plus subscriptionType, or
#               authMethod=oauth_token for the headless subscription token.
#               It also runs the CLI with ANTHROPIC_API_KEY and
#               ANTHROPIC_AUTH_TOKEN SCRUBBED (env -u), so review reasoning
#               bills against the operator's Claude Code PLAN, never the
#               pay-per-token API. CLAUDE_CODE_OAUTH_TOKEN (the subscription
#               headless token) is PRESERVED. If claude is not logged in on a
#               plan the read-only call fails and the orchestrator falls back
#               to the manual handoff (fail-closed).
#   P4B_CLAUDE_PERMISSION_MODE  default: plan (read-only).
#   P4B_CLAUDE_ALLOWED_TOOLS    default: "Read,Bash(git diff *),Bash(git log *)".
#   GH_TOKEN    only used if the diff must be fetched (no --diff-file).
#   P4B_REVIEW_CLI_TIMEOUT_SECONDS  default: P4B_ADAPTER_TIMEOUT_SECONDS
#               or 900. Timeout maps to exit 4 / manual fallback.
#
# Exit codes: identical contract to review-via-codex.sh (0/2/3/4).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

SCHEMA="$HERE/../verdict.schema.json"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
PERMISSION_MODE="${P4B_CLAUDE_PERMISSION_MODE:-plan}"
ALLOWED_TOOLS="${P4B_CLAUDE_ALLOWED_TOOLS:-Read,Bash(git diff *),Bash(git log *)}"

PR="" ; REPO="" ; HEAD="" ; DIFF_FILE="" ; MODEL="${P4B_CLAUDE_MODEL:-}"
CLI_TIMEOUT="${P4B_REVIEW_CLI_TIMEOUT_SECONDS:-${P4B_ADAPTER_TIMEOUT_SECONDS:-900}}"

usage() {
  echo "usage: review-via-claude.sh --pr <N> --repo <owner/repo> [--head <sha>] [--diff-file <path>] [--model <m>]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)        PR="${2:-}"; shift 2 ;;
    --repo)      REPO="${2:-}"; shift 2 ;;
    --head)      HEAD="${2:-}"; shift 2 ;;
    --diff-file) DIFF_FILE="${2:-}"; shift 2 ;;
    --model)     MODEL="${2:-}"; shift 2 ;;
    -h|--help)   usage ;;
    *) echo "review-via-claude.sh: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$PR" ] || usage
command -v jq >/dev/null 2>&1 || p4b_die 3 "jq is required"
[ -r "$SCHEMA" ] || p4b_die 3 "verdict schema not readable: $SCHEMA"

# --- obtain the diff -------------------------------------------------------
DIFF=""
if [ -n "$DIFF_FILE" ]; then
  [ -r "$DIFF_FILE" ] || p4b_die 3 "diff file not readable: $DIFF_FILE"
  DIFF="$(cat "$DIFF_FILE")"
else
  command -v gh >/dev/null 2>&1 || p4b_die 3 "gh is required to fetch the diff (or pass --diff-file)"
  [ -n "$REPO" ] || p4b_die 2 "--repo is required when no --diff-file is given"
  DIFF="$(gh pr diff "$PR" --repo "$REPO" 2>/dev/null)" || p4b_die 4 "failed to fetch PR diff via gh"
fi
[ -n "$DIFF" ] || p4b_die 4 "empty diff — nothing to review"

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || p4b_die 3 "claude CLI not found on PATH (set CLAUDE_BIN)"
p4b_require_claude_plan_auth "$CLAUDE_BIN"

# --- run the review --------------------------------------------------------
REQUIRED_SEVERITIES="$(p4b_required_verdict_severities_json)" \
  || p4b_die 3 "invalid feedback_policy; cannot determine required verdict severities"
SCHEMA_TEXT="$(cat "$SCHEMA")"
PROMPT="You are an external code reviewer for GitHub PR #${PR}${REPO:+ in ${REPO}}${HEAD:+ at commit ${HEAD}}.
Perform an exhaustive code review: keep looking for additional findings until
you stop finding new issues.
The unified diff is on stdin. Respond with ONLY a single JSON object (no
prose, no code fence) conforming to this JSON Schema:
${SCHEMA_TEXT}
verdict must be APPROVED or CHANGES_REQUESTED. Approve only if you would
stake a merge on it. For this repository, these finding severities require
disposition before merge: ${REQUIRED_SEVERITIES}. If any finding with one of
those severities exists, the verdict must be CHANGES_REQUESTED, not APPROVED.
When requesting changes, list every required-severity issue you identify in
this pass, not just the first one.
Set usage to null; the adapter will populate CLI usage metadata if the CLI
exposes it. Do not edit files. Do not post anything to GitHub."

set +e
ENVELOPE="$(
  printf '%s\n' "$DIFF" | p4b_run_with_timeout "$CLI_TIMEOUT" env \
    -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    -u OP_PREFLIGHT_REVIEWER_PAT -u OP_PREFLIGHT_AUTHOR_PAT \
    "$CLAUDE_BIN" -p "$PROMPT" \
    --permission-mode "$PERMISSION_MODE" \
    --output-format json \
    ${MODEL:+--model "$MODEL"} \
    --allowedTools "$ALLOWED_TOOLS" 2>/dev/null
)"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  if p4b_is_timeout_rc "$RC"; then
    p4b_die 4 "claude -p timed out after ${CLI_TIMEOUT}s — falling back to the manual handoff"
  fi
  p4b_die 4 "claude -p failed (rc=$RC) — ensure claude is logged in on a plan (API keys are scrubbed for plan-only billing); falling back to the manual handoff"
fi
[ -n "$ENVELOPE" ] || p4b_die 4 "claude -p produced no output"

# Extract the model's answer from the print-mode JSON envelope (.result).
# Tolerate a fake/older CLI that emits the verdict JSON directly (no
# envelope): fall back to treating the whole output as the candidate.
RESULT="$(printf '%s' "$ENVELOPE" | jq -r '.result // empty' 2>/dev/null || true)"
[ -n "$RESULT" ] || RESULT="$ENVELOPE"

VERDICT_JSON="$(p4b_extract_json_block "$RESULT")"
VERDICT_JSON="$(printf '%s' "$VERDICT_JSON" | jq -c 'if has("usage") then . else . + {usage: null} end' 2>/dev/null || true)"
if ! p4b_validate_verdict "$VERDICT_JSON"; then
  p4b_warn "claude output did not conform to verdict.schema.json (fail-closed)"
  exit 4
fi

USAGE="$(printf '%s' "$ENVELOPE" | jq -c '
  def int_or_null: if type == "number" then floor else null end;
  if type != "object" then null
  else
    ( .usage.total_tokens
      // .usage.total
      // .usage.token_count
      // .total_tokens
      // .metrics.total_tokens
      // (if (.usage.input_tokens? != null and .usage.output_tokens? != null)
          then (.usage.input_tokens + .usage.output_tokens)
          else null end)
    ) as $total
    | ( .usage.input_tokens // .input_tokens // .metrics.input_tokens // null ) as $input
    | ( .usage.output_tokens // .output_tokens // .metrics.output_tokens // null ) as $output
    | if $total == null and $input == null and $output == null then null
      else {
        token_count: ($total | int_or_null),
        input_tokens: ($input | int_or_null),
        output_tokens: ($output | int_or_null),
        source: "claude-json-envelope"
      }
      end
  end
' 2>/dev/null || printf 'null')"

printf '%s' "$VERDICT_JSON" | jq -c --argjson usage "$USAGE" '. + {usage: $usage}'
exit 0
