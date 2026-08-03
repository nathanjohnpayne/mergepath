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
# The decision reuses the EXISTING `external-review:v2` fingerprint — the same
# one scripts/workflow/external_review_fingerprint.sh computes and
# external_review_carryforward.sh already uses to carry a prior Codex verdict
# across an update-branch (#705). There is deliberately no second notion of
# "unchanged": if two heads share a fingerprint, Codex has already reviewed
# byte-identical tree entries for every path this PR changes, at both the head
# and the merge base, so a re-review can only re-derive what it already said.
# The sufficiency argument for a fingerprint match is recorded in
# external_review_carryforward.sh (#763) and is not restated here.
#
# The decision is deliberately NOT symmetric:
#
#   - Suppressing needs POSITIVE evidence: a fingerprint that equals the
#     fingerprint of a commit Codex has demonstrably reviewed.
#   - Everything else — no fingerprint, an unreadable API, a helper failure, an
#     unresolvable commit — returns `trigger:true`. Over-triggering costs one
#     redundant review; under-triggering silently drops the explicit-invocation
#     requirement (#631/#648) that a fix push must re-arm HEAD-anchored Codex
#     clearance. So every uncertainty resolves toward posting.
#
# Timestamps are never consulted as evidence of "nothing changed" — only as an
# ordering key among Codex's own signals. A rebase can move an actor-controlled
# commit date at will (that is why no gate in this repo keys freshness off one),
# and the fingerprint is content-derived, so a spoofed date cannot manufacture
# a match.
#
# Inputs:
#   --repo owner/repo
#   --pr <number>
#   --head <sha>             the head the automatic trigger would review
#   --config <path>          default: .github/review-policy.yml
#   --files-json <path>      optional PR files JSON cache (as the callers in
#                            agent-review.yml already build for the labelers)
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

# Bounds the API cost of the scan below: each candidate can cost a commit
# lookup plus a fingerprint (which itself fetches two trees). A match is
# normally found on the first candidate — the head Codex reviewed immediately
# before the update-branch — so this cap only bites on a long-lived PR with
# many superseded rounds, where the older heads are the least likely to match
# anyway.
MAX_CANDIDATES=10

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

FINGERPRINT_BIN="$SCRIPT_DIR/external_review_fingerprint.sh"

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

# Keep stdout and stderr separate on a successful gh call so a warning/notice
# cannot leak into text the caller parses as JSON, and preserve the real exit
# code on failure. Same helper, same rationale as
# external_review_fingerprint.sh (#715) and external_review_carryforward.sh
# (#716); duplicated rather than shared because these run as separate
# processes.
gh_api_capture() {
  local err_file rc=0 out
  err_file=$(mktemp "${TMPDIR:-/tmp}/codex-auto-trigger-gh-err.XXXXXX") || {
    "$@" 2>&1
    return $?
  }
  out=$("$@" 2>"$err_file") || rc=$?
  if [ "$rc" -ne 0 ]; then
    out="$out
$(cat "$err_file" 2>/dev/null)"
  fi
  rm -f "$err_file"
  printf '%s' "$out"
  return "$rc"
}

TMP_FILES=""
cleanup() {
  [ -z "$TMP_FILES" ] || rm -f "$TMP_FILES"
}
trap cleanup EXIT

if [ ! -x "$FINGERPRINT_BIN" ] && [ ! -f "$FINGERPRINT_BIN" ]; then
  emit true "external_review_fingerprint.sh is unavailable; cannot prove the head is content-free"
fi

if [ ! -f "$CONFIG" ]; then
  emit true "review policy not found at $CONFIG; cannot compute an external-review fingerprint"
fi

# One PR files list serves every ref, exactly as external_review_carryforward.sh
# does it: the changed-path set is a property of the PR, and comparing two refs
# over DIFFERENT path sets would compare two different questions.
if [ -z "$FILES_JSON_PATH" ]; then
  TMP_FILES=$(mktemp "${TMPDIR:-/tmp}/codex-auto-trigger-files.XXXXXX") || \
    emit true "could not create a temp file for the PR files list"
  if ! RAW_FILES=$(gh_api_capture gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files"); then
    echo "codex_auto_trigger_gate.sh: failed to fetch PR files: $RAW_FILES" >&2
    emit true "PR files list unreadable; cannot prove the head is content-free"
  fi
  if ! printf '%s\n' "$RAW_FILES" | jq -s 'add // []' > "$TMP_FILES"; then
    emit true "PR files list did not parse; cannot prove the head is content-free"
  fi
  FILES_JSON_PATH="$TMP_FILES"
fi

fingerprint_at() {
  local ref=$1 out rc=0
  out=$(bash "$FINGERPRINT_BIN" \
    --repo "$REPO" --pr "$PR_NUMBER" --ref "$ref" \
    --config "$CONFIG" --files-json "$FILES_JSON_PATH" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | jq -r '.fingerprint // ""' 2>/dev/null || return 1
}

CURRENT_FINGERPRINT=$(fingerprint_at "$HEAD_SHA") || \
  emit true "could not fingerprint the current head $HEAD_SHA; cannot prove it is content-free"

if [ -z "$CURRENT_FINGERPRINT" ]; then
  # An empty fingerprint means the PR does not require external review, or the
  # files API capped the diff. Either way there is nothing to compare, so the
  # automatic trigger keeps its pre-#798 behavior.
  emit true "no external-review fingerprint for this head; nothing to compare"
fi

COMMENTS_JSON=$(gh_api_capture gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments") || {
  echo "codex_auto_trigger_gate.sh: failed to fetch issue comments: $COMMENTS_JSON" >&2
  emit true "issue comments unreadable; cannot identify a previously reviewed head" "$CURRENT_FINGERPRINT"
}
COMMENTS_JSON=$(printf '%s\n' "$COMMENTS_JSON" | jq -s 'add // []') || \
  emit true "issue comments did not parse; cannot identify a previously reviewed head" "$CURRENT_FINGERPRINT"

REVIEWS_JSON=$(gh_api_capture gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews") || {
  echo "codex_auto_trigger_gate.sh: failed to fetch reviews: $REVIEWS_JSON" >&2
  emit true "reviews unreadable; cannot identify a previously reviewed head" "$CURRENT_FINGERPRINT"
}
REVIEWS_JSON=$(printf '%s\n' "$REVIEWS_JSON" | jq -s 'add // []') || \
  emit true "reviews did not parse; cannot identify a previously reviewed head" "$CURRENT_FINGERPRINT"

# Codex reports through BOTH endpoints and neither alone is sufficient — a
# findings round arrives ONLY as a COMMENTED review object (anchored by
# `commit_id`), a clean verdict ONLY as an issue comment (anchored by a
# `Reviewed commit: <sha>` line). Both are evidence that Codex looked at that
# commit, which is the only thing this gate needs; the DISPOSITION is
# irrelevant here. A findings round that is still open stays open — suppressing
# a redundant re-review of identical content does not clear it, and the fix
# push that resolves it changes the fingerprint and re-triggers.
CANDIDATES=$(jq -n -r \
  --arg bot "$BOT_LOGIN" \
  --argjson comments "$COMMENTS_JSON" \
  --argjson reviews "$REVIEWS_JSON" '
  def verdict_shas($body):
    [ $body
      | ascii_downcase
      | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
      | .[0]
    ];
  ([
    $comments[]
    | select(.user.login == $bot)
    | . as $c
    | verdict_shas($c.body // "")[] as $sha
    | {time: ($c.created_at // ""), sha: $sha}
  ] + [
    $reviews[]
    | select(.user.login == $bot)
    | {time: (.submitted_at // ""), sha: ((.commit_id // "") | ascii_downcase)}
  ])
  | map(select(.time != "" and .sha != ""))
  | sort_by(.time)
  | reverse
  | unique_by(.sha)
  | sort_by(.time)
  | reverse
  | .[]
  | [.time, .sha]
  | @tsv
')

if [ -z "$CANDIDATES" ]; then
  emit true "no Codex-reviewed commit on this PR to compare against" "$CURRENT_FINGERPRINT"
fi

HEAD_LC=$(printf '%s' "$HEAD_SHA" | tr '[:upper:]' '[:lower:]')
examined=0
while IFS=$'\t' read -r candidate_time candidate_sha; do
  [ -n "$candidate_sha" ] || continue
  [ "$examined" -lt "$MAX_CANDIDATES" ] || break
  examined=$((examined + 1))

  # Anchors are scanned out of comment prose and are frequently abbreviated, so
  # resolve each to a full SHA. Skipping an unresolvable candidate is the
  # conservative direction: it can only lose a chance to suppress, never
  # suppress on evidence that was not verified.
  resolved_sha=""
  candidate_lc=$(printf '%s' "$candidate_sha" | tr '[:upper:]' '[:lower:]')
  case "$HEAD_LC" in
    "$candidate_lc"*) resolved_sha="$HEAD_SHA" ;;
  esac
  if [ -z "$resolved_sha" ]; then
    resolved_sha=$(gh api "repos/$REPO/commits/$candidate_sha" --jq .sha 2>/dev/null || true)
  fi
  [ -n "$resolved_sha" ] || continue

  candidate_fingerprint=$(fingerprint_at "$resolved_sha") || continue
  [ -n "$candidate_fingerprint" ] || continue

  if [ "$candidate_fingerprint" = "$CURRENT_FINGERPRINT" ]; then
    emit false \
      "Codex already reviewed this external-review fingerprint on $resolved_sha; the new head changes no reviewable content (#798)" \
      "$CURRENT_FINGERPRINT" "$resolved_sha" "$candidate_time"
  fi
done <<<"$CANDIDATES"

emit true "no Codex-reviewed commit matched the current external-review fingerprint" "$CURRENT_FINGERPRINT"
