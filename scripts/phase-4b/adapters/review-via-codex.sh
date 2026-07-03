#!/usr/bin/env bash
# scripts/phase-4b/adapters/review-via-codex.sh
#
# Phase 4b reviewer adapter — Direction A (Claude -> Codex). Drives the
# OpenAI Codex CLI in non-interactive, read-only mode to review a PR diff
# and emit a normalized verdict object (verdict.schema.json) on stdout.
#
# REFERENCE IMPLEMENTATION. It does the REASONING only; it never posts to
# GitHub. The orchestrator (scripts/phase-4b-review.sh) posts the verdict
# under the reviewer PAT via scripts/gh-as-reviewer.sh so attribution is
# the verified reviewer identity, not the CLI's ambient token.
#
# Docs (verbatim flags):
#   codex --ask-for-approval never exec --sandbox read-only \
#     --output-schema <schema> -o <file> "<prompt>"   (stdin = extra context)
#   https://developers.openai.com/codex/noninteractive
#   https://developers.openai.com/codex/cli/reference
# Codex has no `codex review` subcommand and no native review STATE, so we
# impose structure with --output-schema and map it to a verdict here.
#
# Usage:
#   review-via-codex.sh --pr <N> --repo <owner/repo> [--head <sha>]
#                       [--diff-file <path>] [--model <m>]
#
# Env:
#   CODEX_BIN   codex executable (default: codex). Tests point this at a fake.
#   codex login (subscription plan)   reasoning-plane auth. This adapter
#               requires ~/.codex/auth.json auth_mode=chatgpt and launches the
#               CLI with a tightly allowlisted environment, so review reasoning
#               bills against the operator's ChatGPT/Codex PLAN, never the
#               pay-per-token API, and prompt-injected diffs cannot read
#               ambient GitHub/deploy/cloud credential env vars. A persisted
#               API-key login or a stray key in the environment can NOT divert
#               a handoff to metered billing; the adapter exits 4 and the
#               orchestrator falls back to the manual handoff (fail-closed).
#               This also honors the Codex docs' warning against exposing
#               OPENAI_API_KEY/CODEX_API_KEY as job-level env around
#               repo-controlled code.
#   GH_TOKEN    only used if the diff must be fetched (no --diff-file).
#   P4B_REVIEW_CLI_TIMEOUT_SECONDS  default: P4B_ADAPTER_TIMEOUT_SECONDS
#               or 900. Timeout maps to exit 4 / manual fallback.
#   P4B_CODEX_EFFORT  reasoning effort (minimal|low|medium|high|xhigh). Empty/unset
#               ⇒ omit the flag and use the Codex CLI default. Maps to
#               `codex -c model_reasoning_effort=<v>`. The orchestrator sets
#               this from phase_4b_automation.codex_effort.
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
#
# Exit codes:
#   0  valid verdict JSON on stdout.
#   2  usage error.
#   3  missing dependency (codex/jq/gh) or unreadable schema.
#   4  adapter could not produce a VALID verdict (CLI error, timeout, or
#      non-conformant output) — the orchestrator falls back to the manual
#      handoff. Fail-closed: never emits an APPROVED on doubt.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

SCHEMA="$HERE/../verdict.schema.json"
CODEX_BIN="${CODEX_BIN:-codex}"

PR="" ; REPO="" ; HEAD="" ; DIFF_FILE="" ; MODEL="${P4B_CODEX_MODEL:-}"
SANDBOX=read-only
CLI_TIMEOUT="${P4B_REVIEW_CLI_TIMEOUT_SECONDS:-${P4B_ADAPTER_TIMEOUT_SECONDS:-900}}"
# Reasoning effort (#589). Empty ⇒ omit the flag and use the Codex CLI default
# (historical behavior). When set it maps to `-c model_reasoning_effort=<v>`,
# the config knob exposed by codex-cli 0.137. --strict-config is intentionally
# NOT used, so an unrecognized key on a future CLI is a harmless no-op.
EFFORT="${P4B_CODEX_EFFORT:-}"

usage() {
  echo "usage: review-via-codex.sh --pr <N> --repo <owner/repo> [--head <sha>] [--diff-file <path>] [--model <m>]" >&2
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
    *) echo "review-via-codex.sh: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$PR" ] || usage
command -v jq >/dev/null 2>&1 || p4b_die 3 "jq is required"
[ -r "$SCHEMA" ] || p4b_die 3 "verdict schema not readable: $SCHEMA"
case "$EFFORT" in
  ''|minimal|low|medium|high|xhigh) ;;
  *) p4b_die 3 "invalid P4B_CODEX_EFFORT '$EFFORT' (expected minimal|low|medium|high|xhigh)" ;;
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

command -v "$CODEX_BIN" >/dev/null 2>&1 || p4b_die 3 "codex CLI not found on PATH (set CODEX_BIN)"
p4b_require_codex_plan_auth
CODEX_AUTH_SOURCE="$(p4b_codex_auth_file)"

TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/p4b-codex.XXXXXX")"
ERR_OUT="$(mktemp "${TMPDIR:-/tmp}/p4b-codex-stderr.XXXXXX")"
DIFF_RAW="$(mktemp "${TMPDIR:-/tmp}/p4b-codex-diff-raw.XXXXXX")"
DIFF_FIT="$(mktemp "${TMPDIR:-/tmp}/p4b-codex-diff-fit.XXXXXX")"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/p4b-codex-run.XXXXXX")"
RUN_HOME="$(mktemp -d "${TMPDIR:-/tmp}/p4b-codex-home.XXXXXX")"
RUN_CODEX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/p4b-codex-auth.XXXXXX")"
cp "$CODEX_AUTH_SOURCE" "$RUN_CODEX_HOME/auth.json"
chmod 600 "$RUN_CODEX_HOME/auth.json" 2>/dev/null || true
# shellcheck disable=SC2064
trap "rm -f '$TMP_OUT' '$ERR_OUT' '$DIFF_RAW' '$DIFF_FIT'; rm -rf '$RUN_DIR' '$RUN_HOME' '$RUN_CODEX_HOME'" EXIT

# --- bound the diff to the review byte budget (#635) ------------------------
MAX_DIFF_BYTES="$(p4b_resolve_diff_max_bytes)" \
  || p4b_die 3 "invalid diff byte budget (P4B_DIFF_MAX_BYTES must be an integer; phase_4b_automation.diff_max_bytes must be an integer in ${P4B_MIN_DIFF_MAX_BYTES}..${P4B_MAX_DIFF_MAX_BYTES})"
printf '%s\n' "$DIFF" > "$DIFF_RAW"
DIFF_BYTES="$(wc -c < "$DIFF_RAW" | tr -d '[:space:]')"
OMIT_GLOBS="$(p4b_diff_omit_globs)"
OMITTED="$(p4b_trim_review_diff "$DIFF_RAW" "$DIFF_FIT" "$MAX_DIFF_BYTES" "$OMIT_GLOBS")" \
  || p4b_die 4 "diff (${DIFF_BYTES} bytes) exceeds the ${MAX_DIFF_BYTES}-byte review budget and cannot be reduced by omitting policy-allowlisted bulk sections (phase_4b_automation.diff_omit_globs) — refusing to omit unreviewed code (#636); pass a curated --diff-file or extend the allowlist; falling back to the manual handoff"
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
finding new issues.
The unified diff is provided on stdin. Return ONLY a JSON object conforming
to the provided output schema: a 'verdict' of APPROVED or CHANGES_REQUESTED,
a short 'summary', and a 'findings' array ({severity P0-P3, path, line, body}).
Set usage to null and cli_version to null; the adapter records CLI usage and
version only from outside the model response, never from a self-report.
Approve only if you would stake a merge on it; otherwise
request changes and list every required-severity issue you identify in this
pass, not just the first one. For this repository, these finding severities
require disposition before merge: ${REQUIRED_SEVERITIES}.
If any finding with one of those severities exists, the verdict must be
CHANGES_REQUESTED, not APPROVED. Do not edit files. Do not post anything to
GitHub.${DIFF_NOTE}"

SAFE_ENV=(env -i
  "PATH=${PATH:-/usr/bin:/bin}"
  "HOME=$RUN_HOME"
  "USER=${USER:-}"
  "LOGNAME=${LOGNAME:-}"
  "SHELL=${SHELL:-/bin/sh}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "LANG=${LANG:-C}"
  "TERM=${TERM:-dumb}"
  "CODEX_HOME=$RUN_CODEX_HOME"
)

# Codex CLI v0.137 exposes --ask-for-approval as a global flag; placing it
# after `exec` is rejected by `codex exec --help` / argument parsing.
set +e
RAW="$(
  printf '%s\n' "$DIFF" | p4b_run_with_timeout "$CLI_TIMEOUT" \
    "${SAFE_ENV[@]}" \
    "$CODEX_BIN" \
    --ask-for-approval never \
    exec \
    --cd "$RUN_DIR" \
    --skip-git-repo-check \
    --ephemeral \
    --ignore-user-config \
    --ignore-rules \
    --sandbox "$SANDBOX" \
    ${MODEL:+--model "$MODEL"} \
    ${EFFORT:+-c model_reasoning_effort="$EFFORT"} \
    --output-schema "$SCHEMA" \
    -o "$TMP_OUT" \
    "$PROMPT" 2>"$ERR_OUT"
)"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  ERR_TAIL="$(p4b_stderr_tail "$ERR_OUT")"
  if p4b_is_timeout_rc "$RC"; then
    p4b_die 4 "codex exec timed out after ${CLI_TIMEOUT}s${ERR_TAIL:+ — last stderr: ${ERR_TAIL}} — falling back to the manual handoff"
  fi
  p4b_die 4 "codex exec failed (rc=$RC)${ERR_TAIL:+ — stderr: ${ERR_TAIL}} — if this is an auth error, ensure 'codex login' is active on a plan (child env is allowlisted for plan-only billing); falling back to the manual handoff"
fi

# Prefer the --output-last-message file; fall back to captured stdout.
CANDIDATE=""
if [ -s "$TMP_OUT" ]; then
  CANDIDATE="$(cat "$TMP_OUT")"
else
  CANDIDATE="$RAW"
fi

VERDICT_JSON="$(p4b_extract_json_block "$CANDIDATE")"
VERDICT_JSON="$(printf '%s' "$VERDICT_JSON" | jq -c '
  (if has("usage") then . else . + {usage: null} end)
  | (if has("cli_version") then . else . + {cli_version: null} end)
' 2>/dev/null || true)"
if ! p4b_validate_verdict "$VERDICT_JSON"; then
  p4b_warn "codex output did not conform to verdict.schema.json (fail-closed)"
  exit 4
fi

TOKEN_COUNT="$(awk '
  seen {
    value=$1
    gsub(/,/, "", value)
    if (value ~ /^[0-9]+$/) { print value; exit }
    seen=0
  }
  /tokens used/ { seen=1 }
' "$ERR_OUT" 2>/dev/null || true)"

if [ -n "$TOKEN_COUNT" ]; then
  # All eight usage keys, null-filled: verdict.schema.json is
  # required-complete for OpenAI strict mode (#632), so an emitter must
  # never omit a key it lacks a value for.
  USAGE="$(jq -n --argjson token "$TOKEN_COUNT" \
    '{token_count:$token,input_tokens:null,output_tokens:null,cache_creation_input_tokens:null,cache_read_input_tokens:null,reasoning_tokens:null,total_cost_usd:null,source:"codex-cli-stderr"}')"
else
  USAGE="null"
fi

# Reviewer CLI version (#622): best-effort, CLI-sourced only — never the
# model's self-report (the prompt pins cli_version to null for exactly this
# reason). A separate `--version` invocation, not parsed from the review run
# itself, so a malformed or JSON-shaped response (e.g. a misbehaving/fake
# CLI) is rejected rather than surfacing as a bogus version string.
# Timeout-bounded (CodeRabbit): this probe sits outside the already-bounded
# review path, so a hung CLI must not stall verdict emission — a stuck
# `--version` degrades to null, same as any other capture failure.
CLI_VERSION_JSON="null"
if CLI_VERSION_RAW="$(p4b_run_with_timeout 10 "$CODEX_BIN" --version 2>/dev/null)"; then
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
