#!/usr/bin/env bash
set -euo pipefail

# Decide whether an AUTOMATIC `@codex review` trigger should be posted for the
# current PR head (#798).
#
# The problem: branch protection on `main` sets `required_status_checks.strict:
# true`, so every merge forces `gh pr update-branch` on every other open PR.
# That produces a NEW HEAD SHA which changes no file in the PR's own diff, and
# the automatic trigger path (agent-review.yml's auto-merge job →
# coderabbit-wait.sh's #489 rate-limit failover → codex-review-request.sh
# --trigger-only) re-requested a full Codex review for it. With `Codex P1
# unresolved threads` required, each such review round can re-red a required
# gate, so a batch of N concurrent PRs costs O(N²) review rounds none of which
# respond to an actual code change.
#
# The decision is DELEGATED to scripts/workflow/external_review_carryforward.sh
# — the #705 helper that decides whether a prior Codex verdict carries across an
# `update-branch`, over the EXISTING `external-review:v2` fingerprint. This gate
# suppresses if and only if that helper reports `carried: true`.
#
# Delegating rather than re-deriving the question is the whole design, and it is
# a correction (Codex P1 on the PR for #798). An earlier revision ran its own
# scan and accepted ANY Codex signal on a commit — including a `COMMENTED`
# review object, i.e. a findings round. Carry-forward accepts strictly less: an
# AFFIRMATIVE issue-comment verdict, and only when no newer non-affirmative
# signal supersedes it. Suppressing on evidence carry-forward would reject
# stranded the head: no head-anchored Codex signal, no carry-forward clearance,
# and — because the failover still reports `codex_failover_requested: true` —
# nothing left that would ever re-request the review. The merge-clearance gate
# then waits forever for a review nobody asked for.
#
# So the suppression condition is now, by construction, the condition under
# which codex-review-check.sh's gate (c) clears this head: both ask the same
# helper the same question. A copied predicate could drift; a delegated one
# cannot. It also inherits carry-forward's newer-signal revocation, its
# `codex.enabled: false` short-circuit, and its fail-closed handling of an
# unresolvable newer signal.
#
# The decision is deliberately NOT symmetric:
#
#   - Suppressing needs POSITIVE evidence: `carried: true` from the helper.
#   - Everything else — a missing or non-executable helper, a nonzero exit,
#     unparseable output, any `carried: false` — returns `trigger:true`.
#     Over-triggering costs one redundant review; under-triggering silently
#     drops the explicit-invocation requirement (#631/#648) that a fix push must
#     re-arm HEAD-anchored Codex clearance. So every uncertainty resolves toward
#     posting.
#
# Timestamps are never consulted as evidence of "nothing changed" — carry-forward
# uses them only to order Codex's own signals. A rebase can move an
# actor-controlled commit date at will (that is why no gate in this repo keys
# freshness off one), and the fingerprint is content-derived, so a spoofed date
# cannot manufacture a match.
#
# Inputs:
#   --repo owner/repo
#   --pr <number>
#   --head <sha>             the head the automatic trigger would review
#   --config <path>          default: .github/review-policy.yml
#   --files-json <path>      optional PR files JSON cache (as the callers in
#                            agent-review.yml already build for the labelers),
#                            passed straight through to the carry-forward helper
#   --bot-login <login>      default: chatgpt-codex-connector[bot]
#
# Output (stdout, always valid JSON; exit 0 unless the invocation itself is
# malformed):
#   {
#     "trigger": true|false,
#     "reason": "...",
#     "fingerprint": "external-review:v2:<sha256>" | "",
#     "reviewed_commit": "<sha>" | "",
#     "reviewed_at": "<iso-8601>" | ""
#   }
#
# Exit codes:
#   0  decision emitted (read `.trigger`)
#   2  usage error / missing dependency (no decision; the caller posts)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=".github/review-policy.yml"
REPO=""
PR_NUMBER=""
HEAD_SHA=""
FILES_JSON_PATH=""
BOT_LOGIN="chatgpt-codex-connector[bot]"

usage() {
  cat >&2 <<'EOF'
usage: codex_auto_trigger_gate.sh --repo owner/repo --pr N --head SHA [--config path] [--files-json path] [--bot-login login]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"; shift 2 ;;
    --pr)
      [ $# -ge 2 ] || usage
      PR_NUMBER="$2"; shift 2 ;;
    --head)
      [ $# -ge 2 ] || usage
      HEAD_SHA="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || usage
      CONFIG="$2"; shift 2 ;;
    --files-json)
      [ $# -ge 2 ] || usage
      FILES_JSON_PATH="$2"; shift 2 ;;
    --bot-login)
      [ $# -ge 2 ] || usage
      BOT_LOGIN="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "codex_auto_trigger_gate.sh: unknown arg: $1" >&2
      usage ;;
  esac
done

[ -n "$REPO" ] || usage
[ -n "$PR_NUMBER" ] || usage
[ -n "$HEAD_SHA" ] || usage
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "codex_auto_trigger_gate.sh: --pr must be an integer" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "codex_auto_trigger_gate.sh: jq is required" >&2; exit 2; }

CARRYFORWARD_BIN="$SCRIPT_DIR/external_review_carryforward.sh"

# Emit the decision and stop. `trigger` is a JSON boolean so callers can read it
# with `jq -r '.trigger'` without string/boolean ambiguity.
emit() {
  local trigger=$1 reason=$2 fingerprint=${3:-} reviewed_commit=${4:-} reviewed_at=${5:-}
  jq -n \
    --argjson trigger "$trigger" \
    --arg reason "$reason" \
    --arg fingerprint "$fingerprint" \
    --arg reviewed_commit "$reviewed_commit" \
    --arg reviewed_at "$reviewed_at" \
    '{trigger:$trigger, reason:$reason, fingerprint:$fingerprint, reviewed_commit:$reviewed_commit, reviewed_at:$reviewed_at}'
  exit 0
}

if [ ! -f "$CARRYFORWARD_BIN" ]; then
  emit true "external_review_carryforward.sh is unavailable; cannot prove this head carries a prior Codex verdict"
fi

if [ ! -f "$CONFIG" ]; then
  emit true "review policy not found at $CONFIG; cannot evaluate carry-forward"
fi

CARRY_ARGS=(--repo "$REPO" --pr "$PR_NUMBER" --head "$HEAD_SHA" --config "$CONFIG" --bot-login "$BOT_LOGIN")
# The changed-path set is a property of the PR, so a caller that already built
# the files list (agent-review.yml's triage job does) can hand it over and save
# the fetch. Omitted, the helper fetches its own.
[ -z "$FILES_JSON_PATH" ] || CARRY_ARGS+=(--files-json "$FILES_JSON_PATH")

# stderr is inherited so the helper's diagnostics land in the caller's log;
# only stdout is parsed.
CARRY_RC=0
CARRY_JSON=$(bash "$CARRYFORWARD_BIN" "${CARRY_ARGS[@]}") || CARRY_RC=$?
if [ "$CARRY_RC" -ne 0 ]; then
  emit true "external_review_carryforward.sh exited $CARRY_RC; cannot prove this head carries a prior Codex verdict"
fi

# `.carried` must be a JSON BOOLEAN, not merely stringify to "true". `tostring`
# would coerce the string "true" — and a JSON string is what a truncated,
# doubly-encoded, or half-written payload most plausibly degrades into. This is
# the single field that suppresses a review, so a value whose type is wrong is
# treated as no answer at all rather than as consent (CodeRabbit Major on #880).
CARRIED=$(printf '%s' "$CARRY_JSON" \
  | jq -r 'if (.carried | type) == "boolean" then (.carried | tostring) else "parse-error" end' 2>/dev/null) \
  || CARRIED="parse-error"
CARRY_FINGERPRINT=$(printf '%s' "$CARRY_JSON" | jq -r '.fingerprint // ""' 2>/dev/null || printf '')

if [ "$CARRIED" != "true" ]; then
  if [ "$CARRIED" = "parse-error" ]; then
    emit true "external_review_carryforward.sh output did not parse, or reported a non-boolean 'carried'; cannot prove this head carries a prior Codex verdict"
  fi
  CARRY_REASON=$(printf '%s' "$CARRY_JSON" | jq -r '.reason // "no prior Codex verdict carries to this head"' 2>/dev/null || printf 'no prior Codex verdict carries to this head')
  emit true "$CARRY_REASON" "$CARRY_FINGERPRINT"
fi

SOURCE_COMMIT=$(printf '%s' "$CARRY_JSON" | jq -r '.source_commit // ""' 2>/dev/null || printf '')
SOURCE_TIME=$(printf '%s' "$CARRY_JSON" | jq -r '.source_time // ""' 2>/dev/null || printf '')

emit false \
  "a prior Codex verdict on $SOURCE_COMMIT carries to this head on the unchanged external-review fingerprint; the new head changes no reviewable content (#798)" \
  "$CARRY_FINGERPRINT" "$SOURCE_COMMIT" "$SOURCE_TIME"
