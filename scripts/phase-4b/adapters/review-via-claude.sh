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
#   claude -p "<prompt>" --system-prompt "<structured reviewer>" \
#     --permission-mode plan --effort medium --output-format json \
#     --tools ""
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
#               It also runs the CLI with a tightly allowlisted environment,
#               so review reasoning bills against the operator's Claude Code
#               PLAN, never the pay-per-token API, and prompt-injected diffs
#               cannot read ambient GitHub/deploy/cloud credential env vars.
#               CLAUDE_CODE_OAUTH_TOKEN (the subscription headless token) is
#               PRESERVED. If claude is not logged in on a plan the read-only
#               call fails and the orchestrator falls back to the manual
#               handoff (fail-closed).
#   Claude always runs with a text-only system prompt, --permission-mode plan,
#   --effort medium, and --tools "".
#   Environment overrides cannot widen the tool or permission posture.
#   GH_TOKEN    only used if the diff must be fetched (no --diff-file).
#   P4B_CLAUDE_EFFORT  effort level for the Claude run (default: medium).
#   P4B_REVIEW_CLI_TIMEOUT_SECONDS  default: P4B_ADAPTER_TIMEOUT_SECONDS
#               or 900. Timeout maps to exit 4 / manual fallback.
#   P4B_DIFF_MAX_BYTES  review-diff byte budget override (integer; tests and
#               manual runs). Default resolution: the
#               phase_4b_automation.diff_max_bytes policy knob, else 600000.
#               An over-budget diff has its largest ALLOWLISTED per-file
#               sections omitted with in-diff placeholders plus a prompt
#               disclosure naming each omitted path+size (#635); when nothing
#               reviewable survives the budget, exit 4 (manual fallback).
#   P4B_DIFF_OMIT_GLOBS  comma-separated override of the omission allowlist
#               (phase_4b_automation.diff_omit_globs). Only matching paths
#               are ever omitted from an over-budget diff — a non-matching
#               oversized section fails closed to the manual handoff so an
#               APPROVED can never post around unreviewed code (#636 P1).
#               Omission is refused outright (exit 4) when the diff itself
#               touches .github/review-policy.yml — the allowlist's own
#               source of truth — so a PR cannot broaden the allowlist it
#               is judged by (#668).
#
# Exit codes: identical contract to review-via-codex.sh (0/2/3/4).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

SCHEMA="$HERE/../verdict.schema.json"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
PERMISSION_MODE=plan
TOOLS=""
SYSTEM_PROMPT="You are a text-only structured-output code reviewer. Do not use tools. Do not plan implementation. Return exactly the requested JSON object and no prose."
EFFORT="${P4B_CLAUDE_EFFORT:-medium}"

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
case "$EFFORT" in
  low|medium|high|xhigh|max) ;;
  *) p4b_die 3 "invalid P4B_CLAUDE_EFFORT '$EFFORT' (expected low|medium|high|xhigh|max)" ;;
esac

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

ERR_OUT="$(mktemp "${TMPDIR:-/tmp}/p4b-claude-stderr.XXXXXX")"
DIFF_RAW="$(mktemp "${TMPDIR:-/tmp}/p4b-claude-diff-raw.XXXXXX")"
DIFF_FIT="$(mktemp "${TMPDIR:-/tmp}/p4b-claude-diff-fit.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$ERR_OUT' '$DIFF_RAW' '$DIFF_FIT'" EXIT

# --- bound the diff to the review byte budget (#635) ------------------------
MAX_DIFF_BYTES="$(p4b_resolve_diff_max_bytes)" \
  || p4b_die 3 "invalid diff byte budget (P4B_DIFF_MAX_BYTES must be an integer; phase_4b_automation.diff_max_bytes must be an integer in ${P4B_MIN_DIFF_MAX_BYTES}..${P4B_MAX_DIFF_MAX_BYTES})"
printf '%s\n' "$DIFF" > "$DIFF_RAW"
DIFF_BYTES="$(wc -c < "$DIFF_RAW" | tr -d '[:space:]')"
OMIT_GLOBS="$(p4b_diff_omit_globs)"
OMITTED="$(p4b_trim_review_diff "$DIFF_RAW" "$DIFF_FIT" "$MAX_DIFF_BYTES" "$OMIT_GLOBS")" \
  || p4b_die 4 "diff (${DIFF_BYTES} bytes) exceeds the ${MAX_DIFF_BYTES}-byte review budget and cannot be reduced by omitting policy-allowlisted bulk sections (phase_4b_automation.diff_omit_globs) — refusing to omit unreviewed code (#636); omission is also refused outright when the diff touches .github/review-policy.yml, because the PR may have rewritten the very allowlist this run would trust (#668); pass a curated --diff-file or extend the allowlist; falling back to the manual handoff"
DIFF_NOTE=""
if [ -n "$OMITTED" ]; then
  DIFF="$(cat "$DIFF_FIT")"
  OMIT_COUNT="$(printf '%s\n' "$OMITTED" | grep -c .)"
  p4b_log "diff over budget (${DIFF_BYTES} > ${MAX_DIFF_BYTES} bytes): omitted ${OMIT_COUNT} allowlisted file section(s): $(printf '%s\n' "$OMITTED" | awk -F'\t' '{printf "%s%s (%s bytes)", (NR > 1 ? ", " : ""), $1, $2}')"
  DIFF_NOTE="

NOTE: the full PR diff is ${DIFF_BYTES} bytes, over this review's
${MAX_DIFF_BYTES}-byte budget. The per-file diff section(s) listed below
WERE CHANGED BY THIS PR but are omitted from the diff you receive, each
replaced with a '[phase-4b diff-budget: ...]' placeholder line. Only paths
on the repo's operator-declared bulk-artifact allowlist
(phase_4b_automation.diff_omit_globs) are ever omitted this way. Do NOT
report these files as missing from the PR; treat them as
changed-but-unreviewed bulk artifacts:
$(printf '%s\n' "$OMITTED" | awk -F'\t' '{printf "- %s (%s bytes)\n", $1, $2}')
If the omission of any of these prevents a sound verdict, return
CHANGES_REQUESTED and say so in the summary."
fi

# --- run the review --------------------------------------------------------
REQUIRED_SEVERITIES="$(p4b_required_verdict_severities_json)" \
  || p4b_die 3 "invalid feedback_policy; cannot determine required verdict severities"
PROMPT="You are an external code reviewer for GitHub PR #${PR}${REPO:+ in ${REPO}}${HEAD:+ at commit ${HEAD}}.
Exhaustive code review: keep looking for additional findings until you stop
finding new issues, then return the verdict.
The unified diff is on stdin. Respond with ONLY this JSON object shape, with no
prose, no code fence, and no extra keys:
{
  \"verdict\": \"APPROVED or CHANGES_REQUESTED\",
  \"summary\": \"1-4 sentence rationale\",
  \"findings\": [
    {\"severity\":\"P0|P1|P2|P3\",\"path\":\"repo-relative path or null\", \"line\": 123, \"body\":\"finding text\"}
  ],
  \"usage\": null,
  \"cli_version\": null
}
Use an empty findings array for a clean approval. path and line must be null
for PR-level findings. For this repository, these finding severities require
disposition before merge: ${REQUIRED_SEVERITIES}. If any finding with one of
those severities exists, verdict must be CHANGES_REQUESTED, not APPROVED. When
requesting changes, list every required-severity issue you identify in this
pass, not just the first one. Do not edit files. Do not post anything to
GitHub.${DIFF_NOTE}"

SAFE_ENV=(env -i
  "PATH=${PATH:-/usr/bin:/bin}"
  "HOME=${HOME:-}"
  "USER=${USER:-}"
  "LOGNAME=${LOGNAME:-}"
  "SHELL=${SHELL:-/bin/sh}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "LANG=${LANG:-C}"
  "TERM=${TERM:-dumb}"
)
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && SAFE_ENV+=("CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")

set +e
ENVELOPE="$(
  printf '%s\n' "$DIFF" | p4b_run_with_timeout "$CLI_TIMEOUT" \
    "${SAFE_ENV[@]}" \
    "$CLAUDE_BIN" -p "$PROMPT" \
    --system-prompt "$SYSTEM_PROMPT" \
    --permission-mode "$PERMISSION_MODE" \
    --effort "$EFFORT" \
    --output-format json \
    --no-session-persistence \
    --safe-mode \
    --disable-slash-commands \
    --tools "$TOOLS" \
    ${MODEL:+--model "$MODEL"} \
    2>"$ERR_OUT"
)"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  ERR_TAIL="$(p4b_stderr_tail "$ERR_OUT")"
  if p4b_is_timeout_rc "$RC"; then
    p4b_die 4 "claude -p timed out after ${CLI_TIMEOUT}s${ERR_TAIL:+ — last stderr: ${ERR_TAIL}} — falling back to the manual handoff"
  fi
  p4b_die 4 "claude -p failed (rc=$RC)${ERR_TAIL:+ — stderr: ${ERR_TAIL}} — if this is an auth error, ensure claude is logged in on a plan (child env is allowlisted for plan-only billing); falling back to the manual handoff"
fi
[ -n "$ENVELOPE" ] || p4b_die 4 "claude -p produced no output"

# Extract the model's answer from the print-mode JSON envelope (.result).
# Tolerate a fake/older CLI that emits the verdict JSON directly (no
# envelope): fall back to treating the whole output as the candidate.
RESULT="$(printf '%s' "$ENVELOPE" | jq -r '.result // empty' 2>/dev/null || true)"
[ -n "$RESULT" ] || RESULT="$ENVELOPE"

VERDICT_JSON="$(p4b_extract_json_block "$RESULT")"
VERDICT_JSON="$(printf '%s' "$VERDICT_JSON" | jq -c '
  (if has("usage") then . else . + {usage: null} end)
  | (if has("cli_version") then . else . + {cli_version: null} end)
' 2>/dev/null || true)"
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
    # Additive #602 usage fields — populated ONLY from the CLI envelope
    # (optional + nullable in verdict.schema.json), never estimated. Computed
    # BEFORE the emit decision (#615 Codex round 11, P2): a cost-only or
    # cache/reasoning-only envelope (no token totals) used to hit the
    # all-null-tokens bail below and return usage: null, dropping the only
    # CLI-sourced cost signal the accounting could have reported.
    | ((.usage.cache_creation_input_tokens // .usage.cache_creation_tokens // null) | int_or_null) as $cachec
    | ((.usage.cache_read_input_tokens // .usage.cache_read_tokens // null) | int_or_null) as $cacher
    | ((.usage.reasoning_tokens // null) | int_or_null) as $reason
    | ((.total_cost_usd? // null) as $c
       | if ($c | type) == "number" and $c >= 0 then $c else null end) as $cost
    | if $total == null and $input == null and $output == null
         and $cachec == null and $cacher == null and $reason == null and $cost == null
      then null
      else {
        token_count: ($total | int_or_null),
        input_tokens: ($input | int_or_null),
        output_tokens: ($output | int_or_null),
        cache_creation_input_tokens: $cachec,
        cache_read_input_tokens: $cacher,
        reasoning_tokens: $reason,
        total_cost_usd: $cost,
        source: "claude-json-envelope"
      }
      end
  end
' 2>/dev/null || printf 'null')"

# Reviewer CLI version (#622): best-effort, CLI-sourced only — never the
# model's self-report (the prompt pins cli_version to null for exactly this
# reason). A separate `--version` invocation, not parsed from the review run
# itself, so a malformed or JSON-shaped response (e.g. a misbehaving/fake
# CLI) is rejected rather than surfacing as a bogus version string.
# Timeout-bounded (CodeRabbit): this probe sits outside the already-bounded
# review path, so a hung CLI must not stall verdict emission — a stuck
# `--version` degrades to null, same as any other capture failure.
CLI_VERSION_JSON="null"
if CLI_VERSION_RAW="$(p4b_run_with_timeout 10 "$CLAUDE_BIN" --version 2>/dev/null)"; then
  CLI_VERSION_RAW="$(printf '%s' "$CLI_VERSION_RAW" | head -1 | tr -d '\r')"
  case "$CLI_VERSION_RAW" in
    ''|'{'*|'['*) : ;; # empty, or JSON-shaped — leave null
    *)
      if [ "${#CLI_VERSION_RAW}" -le 200 ]; then
        CLI_VERSION_JSON="$(jq -Rn --arg v "$CLI_VERSION_RAW" '$v')"
      fi
      ;;
  esac
fi

printf '%s' "$VERDICT_JSON" | jq -c --argjson usage "$USAGE" --argjson cli_version "$CLI_VERSION_JSON" \
  '. + {usage: $usage, cli_version: $cli_version}'
exit 0
