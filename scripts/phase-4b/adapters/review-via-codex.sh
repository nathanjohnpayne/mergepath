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
#   codex exec --sandbox read-only --ask-for-approval never \
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
#   CODEX_API_KEY / codex login   reasoning-plane auth (NOT exported here;
#               provide it in the environment per the Codex docs' warning
#               against job-level OPENAI_API_KEY/CODEX_API_KEY around
#               repo-controlled code).
#   GH_TOKEN    only used if the diff must be fetched (no --diff-file).
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
SANDBOX="${P4B_CODEX_SANDBOX:-read-only}"

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

# --- run the review --------------------------------------------------------
PROMPT="You are an external code reviewer for GitHub PR #${PR}${REPO:+ in ${REPO}}${HEAD:+ at commit ${HEAD}}.
The unified diff is provided on stdin. Return ONLY a JSON object conforming
to the provided output schema: a 'verdict' of APPROVED or CHANGES_REQUESTED,
a short 'summary', and a 'findings' array ({severity P0-P3, path, line, body}).
Approve only if you would stake a merge on it; otherwise request changes and
list the P0/P1 issues. Do not edit files. Do not post anything to GitHub."

TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/p4b-codex.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$TMP_OUT'" EXIT

set +e
RAW="$(
  printf '%s\n' "$DIFF" | "$CODEX_BIN" exec \
    --sandbox "$SANDBOX" \
    --ask-for-approval never \
    ${MODEL:+--model "$MODEL"} \
    --output-schema "$SCHEMA" \
    -o "$TMP_OUT" \
    "$PROMPT" 2>/dev/null
)"
RC=$?
set -e
[ "$RC" -eq 0 ] || p4b_die 4 "codex exec failed (rc=$RC) — fall back to manual handoff"

# Prefer the --output-last-message file; fall back to captured stdout.
CANDIDATE=""
if [ -s "$TMP_OUT" ]; then
  CANDIDATE="$(cat "$TMP_OUT")"
else
  CANDIDATE="$RAW"
fi

VERDICT_JSON="$(p4b_extract_json_block "$CANDIDATE")"
if ! p4b_validate_verdict "$VERDICT_JSON"; then
  p4b_warn "codex output did not conform to verdict.schema.json (fail-closed)"
  exit 4
fi

# Emit compact, canonical JSON.
printf '%s' "$VERDICT_JSON" | jq -c .
exit 0
