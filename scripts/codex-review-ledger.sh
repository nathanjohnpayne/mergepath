#!/usr/bin/env bash
# scripts/codex-review-ledger.sh — report-only Codex review ledger for one PR
# (#1560, slice 2).
#
# Reads the PR's configured-author Codex requests and every Codex response
# GitHub recorded, attributes responses to requests only where the record
# proves it, and prints the ledger (JSON by default, a short report with
# --summary). The attribution and classification rules are documented in
# scripts/lib/codex-review-ledger.sh.
#
# REPORT ONLY. Nothing reads this ledger to decide anything: it posts nothing,
# changes no label, and no requester, barrier or merge-gate path consults it.
# It exists to produce the evidence the counting and routing decision on
# #1560 is made from.
#
# Usage:
#   scripts/codex-review-ledger.sh [--repo owner/name] [--summary]
#                                  [--retry-window SECONDS] <PR_NUMBER>
#
#   --summary        Print a short human-readable report instead of JSON.
#   --retry-window   Gap within which an unacknowledged, unanswered request
#                    followed by another is flagged as a possible
#                    acknowledgement retry (default 300). Flag only; requests
#                    are never folded.
#
# The configured author, bot login and required feedback tiers come from the
# PR's governing base policy (scripts/workflow/resolve_base_policy.sh), the
# same authority the request cap reads.
#
# Exit codes:
#   0  ledger printed
#   2  bad arguments
#   3  a read failed, or evidence was malformed (nothing is printed)

set -euo pipefail

__LEDGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read-only, so the reviewer PAT is the right one when a preflight cache exists.
if [ -z "${GH_TOKEN:-}" ] && [ -r "$__LEDGER_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__LEDGER_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

for __lib in gh-api-array.sh codex-request-evidence.sh codex-failure-markers.sh \
             feedback-policy-helpers.sh codex-review-ledger.sh; do
  if [ ! -r "$__LEDGER_DIR/lib/$__lib" ]; then
    echo "[codex-review-ledger] ERROR: missing helper: $__LEDGER_DIR/lib/$__lib" >&2
    exit 3
  fi
  # shellcheck source=/dev/null
  . "$__LEDGER_DIR/lib/$__lib"
done

die() { echo "[codex-review-ledger] ERROR: $*" >&2; exit 3; }
usage() { sed -n '16,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

REPO=""
SUMMARY=false
RETRY_WINDOW=300
PR_NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --summary) SUMMARY=true; shift ;;
    --retry-window) [ $# -ge 2 ] || usage; RETRY_WINDOW=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$PR_NUMBER" ] || usage; PR_NUMBER=$1; shift ;;
  esac
done
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$RETRY_WINDOW" =~ ^[0-9]{1,6}$ ]] || usage
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || die "could not detect the repo; pass --repo"
fi

read_array() { # <endpoint> <label>
  gh_api_array "$1" "$2" || die "$GH_API_ARRAY_ERROR"
}

# ---- governing policy --------------------------------------------------------
PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) || die "cannot read PR #$PR_NUMBER"
HEAD_SHA=$(printf '%s' "$PR_JSON" | jq -er '.head.sha') || die "PR #$PR_NUMBER has no head sha"

RESOLVER="$__LEDGER_DIR/workflow/resolve_base_policy.sh"
[ -x "$RESOLVER" ] || die "governing-policy resolver missing: $RESOLVER"
DEFAULT_CONFIG="${MERGEPATH_REVIEW_POLICY_PATH:-.github/review-policy.yml}"
POLICY_FILE=$("$RESOLVER" --repo "$REPO" --pr "$PR_NUMBER" --default-config "$DEFAULT_CONFIG" \
  --materialize-default 2>/dev/null) || die "cannot resolve the governing base policy"
[ -n "$POLICY_FILE" ] && [ -r "$POLICY_FILE" ] || die "governing base policy is unreadable"
cleanup_policy() { [ "$POLICY_FILE" = "$DEFAULT_CONFIG" ] || rm -f "$POLICY_FILE" 2>/dev/null || true; }
trap cleanup_policy EXIT

POLICY_JSON=$(policy_yaml_to_json "$POLICY_FILE" 2>/dev/null) || die "governing base policy does not parse"
AUTHOR=$(printf '%s' "$POLICY_JSON" | jq -er '
  if (type == "object") and has("author_identity") then
    (if (.author_identity | type) == "string" and (.author_identity | length) > 0
     then .author_identity else error("author_identity") end)
  else "nathanjohnpayne" end') || die "governing author_identity is malformed"
BOT=$(printf '%s' "$POLICY_JSON" | jq -r '.codex.bot_login // "chatgpt-codex-connector[bot]"')
# resolve_required_tiers returns 2 for a malformed block; any other status is
# its normal result (its last statement is a conditional echo).
tiers_rc=0
REQUIRED_TIERS=$(resolve_required_tiers "$POLICY_FILE") || tiers_rc=$?
[ "$tiers_rc" -ne 2 ] || die "governing feedback_policy is malformed"
REQUIRED_JSON=$(printf '%s\n' "$REQUIRED_TIERS" | jq -Rsc 'split("\n") | map(select(length > 0))')

# ---- reads -------------------------------------------------------------------
ISSUE_COMMENTS=$(read_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
REVIEWS=$(read_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
REVIEW_COMMENTS=$(read_array "repos/$REPO/pulls/$PR_NUMBER/comments" "review comments")
ISSUE_REACTIONS=$(read_array "repos/$REPO/issues/$PR_NUMBER/reactions" "issue reactions")

# ---- requests (shared grammar; malformed ids fail closed) ---------------------
REQUEST_IDS=$(crqe_trigger_generation "$ISSUE_COMMENTS" "$AUTHOR") \
  || die "a configured-author Codex request comment lacks a positive integer id"
REQUESTS='[]'
while IFS= read -r rid; do
  [ -n "$rid" ] || continue
  created=$(printf '%s' "$ISSUE_COMMENTS" | jq -er --argjson id "$rid" '.[] | select(.id == $id) | .created_at') \
    || die "request $rid has no created_at"
  reactions=$(read_array "repos/$REPO/issues/comments/$rid/reactions" "request $rid reactions")
  # Eyes as it stands now: Codex removes it when the review finishes.
  eyes=$(crqe_ack_present "$reactions" "$BOT" "$created") || die "cannot read the eyes reaction on request $rid"
  REQUESTS=$(printf '%s' "$REQUESTS" | jq -c --argjson id "$rid" --arg t "$created" --argjson e "$eyes" \
    '. + [{id: $id, created_at: $t, eyes_now: $e}]')
done < <(printf '%s' "$REQUEST_IDS" | jq -r '.[]')

# ---- Codex reviews -------------------------------------------------------------
LEDGER_REVIEWS='[]'
while IFS= read -r review; do
  [ -n "$review" ] || continue
  rid=$(printf '%s' "$review" | jq -r '.id')
  body_tiers=$(codex_tiers_of "$(printf '%s' "$review" | jq -r '.body // ""')" \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  roots='[]'
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    tier=$(codex_tier_of "$(printf '%s' "$c" | jq -r '.body // ""')")
    roots=$(printf '%s' "$roots" | jq -c --argjson id "$(printf '%s' "$c" | jq '.id')" \
      --arg tier "${tier:-unmarked}" '. + [{comment_id: $id, tier: $tier}]')
  done < <(printf '%s' "$REVIEW_COMMENTS" | jq -c --argjson rid "$rid" --arg bot "$BOT" \
             '.[] | select(.user.login == $bot and .pull_request_review_id == $rid and .in_reply_to_id == null)')
  replies=$(printf '%s' "$REVIEW_COMMENTS" | jq -c --argjson rid "$rid" --arg bot "$BOT" \
    '[.[] | select(.user.login == $bot and .pull_request_review_id == $rid and .in_reply_to_id != null)]')
  reply_markers='[]'
  while IFS= read -r body; do
    m=$(codex_failure_marker_of "$body")
    [ -z "$m" ] || reply_markers=$(printf '%s' "$reply_markers" | jq -c --arg m "$m" '. + [$m] | unique')
  done < <(printf '%s' "$replies" | jq -r '.[] | (.body // "") | @json' | jq -r '.')
  LEDGER_REVIEWS=$(printf '%s' "$LEDGER_REVIEWS" | jq -c --argjson r "$review" --argjson bt "$body_tiers" \
    --argjson roots "$roots" --argjson nreplies "$(printf '%s' "$replies" | jq 'length')" \
    --argjson markers "$reply_markers" \
    '. + [{id: $r.id, submitted_at: $r.submitted_at, commit_id: $r.commit_id,
           body_tiers: $bt, root_findings: $roots, reply_comments: $nreplies,
           reply_markers: $markers}]')
done < <(printf '%s' "$REVIEWS" | jq -c --arg bot "$BOT" '.[] | select(.user.login == $bot)')

# ---- verdicts, reactions, provider blocks, summary ------------------------------
VERDICTS=$(crqe_verdicts "$ISSUE_COMMENTS" "$BOT" \
  | jq -c '[.[] | {comment_id, created_at, reviewed_sha: (.reviewed_shas | last), affirmative}]') \
  || die "cannot parse Codex verdict comments"
REACTIONS=$(printf '%s' "$ISSUE_REACTIONS" | jq -c --arg bot "$BOT" \
  '[.[] | select(.user.login == $bot and .content == "+1") | {id, created_at}]')
BLOCKS='[]'
while IFS= read -r c; do
  [ -n "$c" ] || continue
  m=$(codex_failure_marker_of "$(printf '%s' "$c" | jq -r '.body // ""')")
  [ -n "$m" ] || continue
  BLOCKS=$(printf '%s' "$BLOCKS" | jq -c --argjson c "$c" --arg m "$m" \
    '. + [{comment_id: $c.id, created_at: $c.created_at, reason: $m}]')
done < <(printf '%s' "$ISSUE_COMMENTS" | jq -c --arg bot "$BOT" '
  .[] | select(.user.login == $bot)
      # A verdict is never a block notice (codex-review-request.sh precedence),
      # and the mutable Review Summary is current state, not history.
      | select(((.body // "") | test("(?im)^\\s*codex review:")) | not)
      | select(((.body // "") | startswith("<!-- codex-pull-request-review-summary -->")) | not)')
SUMMARY_JSON=$(crqe_select_codex_review_summary "$ISSUE_COMMENTS" "$BOT" "$HEAD_SHA") \
  || die "cannot read the Codex Review Summary"

INPUTS=$(jq -n \
  --argjson pr "$PR_NUMBER" --arg repo "$REPO" --arg head "$HEAD_SHA" \
  --arg author "$AUTHOR" --arg bot "$BOT" --argjson required "$REQUIRED_JSON" \
  --argjson window "$RETRY_WINDOW" --argjson requests "$REQUESTS" \
  --argjson reviews "$LEDGER_REVIEWS" --argjson verdicts "$VERDICTS" \
  --argjson reactions "$REACTIONS" --argjson blocks "$BLOCKS" --argjson summary "$SUMMARY_JSON" \
  '{pr: $pr, repo: $repo, head_sha: $head, author: $author, bot: $bot,
    required_tiers: $required, retry_window_seconds: $window, requests: $requests,
    reviews: $reviews, verdicts: $verdicts, reactions: $reactions, blocks: $blocks,
    summary: $summary}')
LEDGER=$(crl_ledger "$INPUTS") || die "ledger computation failed"

if [ "$SUMMARY" != true ]; then
  printf '%s\n' "$LEDGER"
  exit 0
fi

printf '%s\n' "$LEDGER" | jq -r '
  .summary as $s
  | "\(.repo)#\(.pr)  head \(.head_sha[0:8])  author \(.author)  required tiers \(.required_tiers | join(","))",
    "requests: \($s.requests)  (eyes now \($s.eyes_now), possible ack retries \($s.possible_ack_retries), re-posted while eyes present \($s.reposted_while_eyes_present))",
    "request outcomes: attributed \($s.outcomes.attributed), ambiguous \($s.outcomes.ambiguous), unanswered \($s.outcomes.unanswered), no response yet \($s.outcomes.no_response_yet)",
    "responses: \($s.responses)  (unsolicited \($s.unsolicited_responses), mixed-head windows \($s.mixed_head_windows), conflicting \($s.conflicting_responses))",
    "responses by class: \($s.responses_by_class | to_entries | map("\(.key)=\(.value)") | join(", "))",
    "blocking responses: \($s.blocking_responses)  (solicited \($s.blocking_responses_solicited))",
    "thread-reply review wrappers (not responses): \($s.thread_reply_reviews)",
    ( .requests[] | select(.outcome == "ambiguous" or .outcome == "unanswered" or .possible_ack_retry_of != null or .reposted_while_eyes_present)
      | "  request \(.id) @ \(.created_at): \(.outcome)"
        + (if .reason then " (\(.reason); candidates \(.candidates | map(tostring) | join(",")))" else "" end)
        + (if .possible_ack_retry_of then " [possible ack retry of \(.possible_ack_retry_of)]" else "" end)
        + (if .reposted_while_eyes_present then " [re-posted while eyes present]" else "" end) )'
