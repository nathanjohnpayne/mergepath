#!/usr/bin/env bash
# scripts/codex-review-ledger.sh — Codex review ledger for one PR
# (#1560, slice 2).
#
# Reads the PR's configured-author Codex requests and every Codex response
# GitHub recorded, attributes responses to requests only where the record
# proves it, and prints the ledger (JSON by default, a short report with
# --summary). The attribution and classification rules are documented in
# scripts/lib/codex-review-ledger.sh.
#
# Read only: it posts nothing and changes no label. Two consumers read it
# (#1560 slice 3): scripts/codex-review-request.sh counts the PR's solicited
# blocking responses for the blocking-review budget, which needs no
# attribution; the Phase 4b barrier's human stops use attribution to decide
# whether a rebuttal was tested (crl_human_stops).
#
# Usage:
#   scripts/codex-review-ledger.sh [--repo owner/name] [--summary]
#                                  [--expect-head <sha>] [--expect-policy <fp>]
#                                  <PR_NUMBER>
#
#   --summary            Print a short human-readable report instead of JSON.
#   --expect-head <sha>  Exit 3 unless the PR head is exactly <sha>.
#   --expect-policy <fp> Exit 3 unless the governing policy snapshot this run
#                        reads has fingerprint <fp> (crqe_policy_fingerprint).
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
EXPECT_HEAD=""
EXPECT_POLICY=""
PR_NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --summary) SUMMARY=true; shift ;;
    --expect-head) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9a-f]{40}$ ]] || usage; EXPECT_HEAD=$2; shift 2 ;;
    --expect-policy) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+-[0-9]+$ ]] || usage; EXPECT_POLICY=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$PR_NUMBER" ] || usage; PR_NUMBER=$1; shift ;;
  esac
done
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || usage
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || die "could not detect the repo; pass --repo"
fi

read_array() { # <endpoint> <label>
  gh_api_array "$1" "$2" || die "$GH_API_ARRAY_ERROR"
}
# Every jq step whose failure would otherwise surface as jq's own status (or,
# inside a loop's process substitution, as nothing at all) goes through this,
# so malformed evidence always exits 3 with nothing printed.
jqx() { # <what> <jq-args...>
  local what=$1
  shift
  jq "$@" || die "malformed evidence: $what"
}

# ---- governing policy --------------------------------------------------------
PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) || die "cannot read PR #$PR_NUMBER"
HEAD_SHA=$(printf '%s' "$PR_JSON" | jq -er '.head.sha') || die "PR #$PR_NUMBER has no head sha"
[ -z "$EXPECT_HEAD" ] || [ "$HEAD_SHA" = "$EXPECT_HEAD" ] \
  || die "PR #$PR_NUMBER head is $HEAD_SHA, not the expected $EXPECT_HEAD"

RESOLVER="$__LEDGER_DIR/workflow/resolve_base_policy.sh"
[ -x "$RESOLVER" ] || die "governing-policy resolver missing: $RESOLVER"
DEFAULT_CONFIG="${MERGEPATH_REVIEW_POLICY_PATH:-.github/review-policy.yml}"
POLICY_FILE=$("$RESOLVER" --repo "$REPO" --pr "$PR_NUMBER" --default-config "$DEFAULT_CONFIG" \
  --materialize-default 2>/dev/null) || die "cannot resolve the governing base policy"
[ -n "$POLICY_FILE" ] && [ -r "$POLICY_FILE" ] || die "governing base policy is unreadable"
# Large evidence travels to jq through files, never argv: a busy PR's comment
# history exceeds the OS argument-size limit (observed on #1541 and
# nathanpaynedotcom#1037 in the #1560 calibration).
LEDGER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-ledger.XXXXXX") || die "cannot create a temporary directory"
cleanup() {
  [ "$POLICY_FILE" = "$DEFAULT_CONFIG" ] || rm -f "$POLICY_FILE" 2>/dev/null || true
  rm -rf "$LEDGER_TMP" 2>/dev/null || true
}
trap cleanup EXIT

POLICY_JSON=$(policy_yaml_to_json "$POLICY_FILE" 2>/dev/null) || die "governing base policy does not parse"
# One snapshot for every policy-derived input (author, bot, tiers, budget): a
# caller that read its own snapshot passes its fingerprint, and a base that
# moved between the two reads is refused rather than mixed.
POLICY_FP=$(crqe_policy_fingerprint "$POLICY_JSON") || die "cannot fingerprint the governing base policy"
[ -z "$EXPECT_POLICY" ] || [ "$POLICY_FP" = "$EXPECT_POLICY" ] \
  || die "the governing base policy changed between the caller's read and this one ($EXPECT_POLICY, now $POLICY_FP)"
# Same rules as crqe_governing_budget: the policy must be an object, and an
# absent author_identity defaults to the shared author.
AUTHOR=$(printf '%s' "$POLICY_JSON" | jq -er '
  if type != "object" then error("policy")
  elif has("author_identity") then
    (if (.author_identity | type) == "string" and (.author_identity | length) > 0
     then .author_identity else error("author_identity") end)
  else "nathanjohnpayne" end') || die "governing policy or its author_identity is malformed"
# A non-string bot login would be coerced to text that matches no Codex
# activity, and an empty ledger would read as zero blocking reviews.
BOT=$(printf '%s' "$POLICY_JSON" | jq -er '
  (if .codex == null then {} else .codex end) | if type != "object" then error("codex")
  elif (.bot_login == null) then ""
  elif (.bot_login | type) == "string" then .bot_login
  else error("bot_login") end') || die "governing codex.bot_login is malformed (must be a string)"
BOT=${BOT:-chatgpt-codex-connector[bot]}
# resolve_required_tiers returns 2 for a malformed block; any other status is
# its normal result (its last statement is a conditional echo).
tiers_rc=0
REQUIRED_TIERS=$(resolve_required_tiers "$POLICY_FILE") || tiers_rc=$?
[ "$tiers_rc" -ne 2 ] || die "governing feedback_policy is malformed"
# The shared tier reader is line-oriented, so a flow-style block
# (`feedback_policy: {mode: address-all}`) reads as no required tiers.
# Cross-check it against the parsed policy and refuse to guess when they
# disagree, rather than add a second tier reader the requester and gate
# would not share.
READER_TIERS=$(printf '%s\n' "$REQUIRED_TIERS" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
# Validate what the parsed policy says before comparing: the shared reader
# ignores values it cannot place, so an invalid mode or priority would
# otherwise read as "nothing required" on both sides and pass (#1574). The
# accepted values are exactly the ones resolve_required_tiers accepts, including
# an empty value (`p1:`), which both read as unset.
printf '%s' "$POLICY_JSON" | jq -e '
  if (has("feedback_policy") | not) then true
  elif (.feedback_policy | type) != "object" then false
  else .feedback_policy as $fp
    | (($fp.mode == null) or ($fp.mode == "by-priority") or ($fp.mode == "address-all"))
      and (($fp.priorities == null) or (($fp.priorities | type) == "object"
           and ($fp.priorities | to_entries
                | all(.value == null or .value == "required" or .value == "discretionary" or .value == "ignore"))))
  end' >/dev/null 2>&1 \
  || die "governing feedback_policy has an invalid mode or priority value (accepted: mode by-priority|address-all; priorities required|discretionary|ignore)"
PARSED_TIERS=$(printf '%s' "$POLICY_JSON" | jq -c '
  ["p0","p1","p2","p3","nitpick"] as $all
  | if (has("feedback_policy") | not) then ["p1"]
    elif (.feedback_policy | type) != "object" then ["__unreadable__"]
    elif (.feedback_policy.mode // "by-priority") == "address-all" then $all
    else .feedback_policy as $fp | [ $all[] | select(($fp.priorities // {})[.] == "required") ] end
  | sort') || die "governing feedback_policy does not parse"
[ "$READER_TIERS" = "$PARSED_TIERS" ] || die "governing feedback_policy reads as $READER_TIERS through the shared tier reader but $PARSED_TIERS when parsed (flow-style YAML?); refusing to guess"
REQUIRED_JSON=$(printf '%s\n' "$REQUIRED_TIERS" | jq -Rsc 'split("\n") | map(select(length > 0))')

# ---- reads -------------------------------------------------------------------
ISSUE_COMMENTS=$(read_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
REVIEWS=$(read_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
REVIEW_COMMENTS=$(read_array "repos/$REPO/pulls/$PR_NUMBER/comments" "review comments")
ISSUE_REACTIONS=$(read_array "repos/$REPO/issues/$PR_NUMBER/reactions" "issue reactions")
printf '%s\n' "$ISSUE_COMMENTS" >"$LEDGER_TMP/issue_comments.json"
printf '%s\n' "$REVIEW_COMMENTS" >"$LEDGER_TMP/review_comments.json"
printf '%s\n' "$REVIEWS" >"$LEDGER_TMP/reviews.json"

# ---- requests ------------------------------------------------------------------
# Counted requests are the configured author's exact commands, by the shared
# grammar the request cap counts (a malformed id fails closed). Foreign
# requests are every other non-bot issue comment, review-thread comment or
# review body that mentions the command in any case: Codex answers those too,
# so they open windows and are attribution candidates, but are not counted.
REQUEST_IDS=$(crqe_trigger_generation "$ISSUE_COMMENTS" "$AUTHOR") \
  || die "a configured-author Codex request comment lacks a positive integer id"
REQUESTS=$(jqx "issue comments" -c --argjson ids "$REQUEST_IDS" '
  [ .[] | select(.id as $i | $ids | index($i))
    | {id, created_at, counted: true, source: "issue_comment", author: .user.login} ]
  | unique_by(.id)' <<<"$ISSUE_COMMENTS")
FOREIGN=$(jqx "request mentions" -nc --slurpfile ic "$LEDGER_TMP/issue_comments.json" \
  --slurpfile rc "$LEDGER_TMP/review_comments.json" --slurpfile rv "$LEDGER_TMP/reviews.json" \
  --argjson ids "$REQUEST_IDS" --arg bot "$BOT" '
  def mentions: (.body // "") | test("@codex review"; "i");
  # Any bot account (CodeRabbit quoting a request, Dependabot, the Codex bot
  # itself) is not a requester.
  def human: ((.user.type // "") != "Bot") and (((.user.login // "") | endswith("[bot]")) | not)
             and ((.user.login // "") != $bot);
  ($ic[0]) as $ic | ($rc[0]) as $rc | ($rv[0]) as $rv
  | [ ($ic[] | select((.id as $i | $ids | index($i)) | not)
            | select(human and mentions)
            | {id, created_at, source: "issue_comment"}),
    ($rc[] | select(human and mentions)
           | {id, created_at, source: "review_comment"}),
    ($rv[] | select(human and mentions)
           | {id, created_at: .submitted_at, source: "review"}) ]
  | map(. + {counted: false, author: null})
  | unique_by([.source, .id])')
FOREIGN=$(jqx "request mentions" -c --slurpfile ic "$LEDGER_TMP/issue_comments.json" \
  --slurpfile rc "$LEDGER_TMP/review_comments.json" --slurpfile rv "$LEDGER_TMP/reviews.json" '
  ($ic[0]) as $ic | ($rc[0]) as $rc | ($rv[0]) as $rv
  | map(. as $f | .author = (
        if $f.source == "issue_comment" then ($ic | map(select(.id == $f.id)) | first | .user.login)
        elif $f.source == "review_comment" then ($rc | map(select(.id == $f.id)) | first | .user.login)
        else ($rv | map(select(.id == $f.id)) | first | .user.login) end))' <<<"$FOREIGN")

# Eyes as they stand now, with their own timestamp (Codex usually removes the
# reaction when the review finishes), for the counted requests.
EYES='{}'
while IFS= read -r rid; do
  [ -n "$rid" ] || continue
  reactions=$(read_array "repos/$REPO/issues/comments/$rid/reactions" "request $rid reactions")
  created=$(jqx "request $rid" -r --argjson id "$rid" 'map(select(.id == $id)) | first | .created_at' <<<"$REQUESTS")
  eyes_at=$(jqx "request $rid reactions" -c --arg bot "$BOT" --arg after "$created" '
    [ .[] | select(.user.login == $bot and .content == "eyes" and .created_at >= $after) | .created_at ]
    | min' <<<"$reactions")
  EYES=$(jqx "eyes" -c --arg id "$rid" --argjson at "$eyes_at" '.[$id] = $at' <<<"$EYES")
done <<<"$(jqx "request ids" -r '.[]' <<<"$REQUEST_IDS")"
printf '%s\n' "$REQUESTS" >"$LEDGER_TMP/counted.json"
printf '%s\n' "$FOREIGN" >"$LEDGER_TMP/foreign.json"
REQUESTS=$(jqx "requests" -c --slurpfile f "$LEDGER_TMP/foreign.json" --argjson eyes "$EYES" '
  map(.eyes_at = $eyes[(.id | tostring)]) + ($f[0] | map(.eyes_at = null))' <"$LEDGER_TMP/counted.json")

# ---- Codex reviews -------------------------------------------------------------
BOT_REVIEWS=$(jqx "reviews" -c --arg bot "$BOT" '[.[] | select(.user.login == $bot)] | unique_by(.id)' <<<"$REVIEWS")
# A Codex review with no submission time cannot be placed in a window; read as
# window 0 it would count as unsolicited and drop out of the blocking budget.
jq -e 'all(.[]; (.submitted_at | type) == "string" and (.submitted_at | length) > 0)' <<<"$BOT_REVIEWS" >/dev/null 2>&1 \
  || die "malformed evidence: a Codex review has no submitted_at"
BOT_REVIEW_COMMENTS=$(jqx "review comments" -c --arg bot "$BOT" \
  '[.[] | select(.user.login == $bot)] | unique_by(.id)' <<<"$REVIEW_COMMENTS")
LEDGER_REVIEWS='[]'
while IFS= read -r review; do
  [ -n "$review" ] || continue
  rid=$(jqx "review" -r '.id' <<<"$review")
  body_tiers=$(codex_tiers_of "$(jqx "review $rid body" -r '.body // ""' <<<"$review")" \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || die "cannot grade review $rid"
  roots='[]'
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    tier=$(codex_tier_of "$(jqx "review comment" -r '.body // ""' <<<"$c")")
    roots=$(jqx "review comment" -c --argjson c "$c" \
      --arg tier "${tier:-unmarked}" '. + [{comment_id: $c.id, tier: $tier, path: ($c.path // null)}]' <<<"$roots")
  done <<<"$(jqx "review $rid comments" -c --argjson rid "$rid" \
               '.[] | select(.pull_request_review_id == $rid and .in_reply_to_id == null)' <<<"$BOT_REVIEW_COMMENTS")"
  replies=$(jqx "review $rid replies" -c --argjson rid "$rid" \
    '[.[] | select(.pull_request_review_id == $rid and .in_reply_to_id != null)]' <<<"$BOT_REVIEW_COMMENTS")
  reply_markers='[]'
  while IFS= read -r encoded; do
    [ -n "$encoded" ] || continue
    m=$(codex_failure_marker_of "$(jqx "reply body" -r '.' <<<"$encoded")")
    [ -z "$m" ] || reply_markers=$(jqx "reply markers" -c --arg m "$m" '. + [$m] | unique' <<<"$reply_markers")
  done <<<"$(jqx "review $rid replies" -c '.[] | (.body // "")' <<<"$replies")"
  LEDGER_REVIEWS=$(jqx "review $rid" -c --argjson r "$review" --argjson bt "$body_tiers" \
    --argjson roots "$roots" --argjson nreplies "$(jqx "replies" 'length' <<<"$replies")" \
    --argjson markers "$reply_markers" \
    '. + [{id: $r.id, submitted_at: $r.submitted_at, commit_id: $r.commit_id,
           body_tiers: $bt, root_findings: $roots, reply_comments: $nreplies,
           reply_markers: $markers}]' <<<"$LEDGER_REVIEWS")
done <<<"$(jqx "reviews" -c '.[]' <<<"$BOT_REVIEWS")"

# ---- rebuttals (#1560 slice 3) ---------------------------------------------------
# A Codex inline finding is rebutted when its thread carries a
# `[mergepath-resolve: rebuttal-recorded]` reply, or its root carries a thumbs-
# down from anyone but the bot (codex-record-feedback.sh's rebutted verdict).
# The rebuttal's time is the LATEST of its proven evidence: the tag replies
# (each at the later of its creation and last edit)
# and the non-bot thumbs-downs. Other replies in the thread are not used: an
# earlier question or fix note would date the rebuttal too early, and a Codex
# response in between would then read as having tested it. Dating late errs
# toward "untested", which stops for the human. A thumbs-down is read only for roots whose
# reaction rollup does not rule one out. Review-body findings are handled
# below, from their review-ack acknowledgements.
REBUTTALS='[]'
while IFS= read -r root; do
  [ -n "$root" ] || continue
  rid=$(jqx "rebuttal root" -r '.id' <<<"$root")
  times=$(jqx "thread $rid replies" -c --argjson rid "$rid" --arg bot "$BOT" '
    [ .[] | select(.in_reply_to_id == $rid and (.user.login // "") != $bot) ] as $replies
    | [ $replies[] | select((.body // "") | test("\\[mergepath-resolve:\\s*rebuttal-recorded\\]"))
        # An existing reply edited to carry the tag dates from the edit: its
        # creation time could predate a Codex review that never saw the tag.
        | ([.created_at, .updated_at] | map(select(type == "string")) | max) ]' <<<"$REVIEW_COMMENTS")
  sources=$(jqx "thread $rid" -c 'if length > 0 then ["tag"] else [] end' <<<"$times")
  # Assigned in a plain statement, not inside the test: a failure inside a
  # command substitution used as an `if` operand escapes set -e, and a
  # malformed rollup would then read as "no thumbs-down" (#1582).
  rollup_says_down=$(jqx "root $rid reactions rollup" -r '
    # Default only an ABSENT rollup: `// {}` would also turn a present false
    # or null into {} and skip the fail-closed path (#1584).
    (if has("reactions") then .reactions else {} end)
    | if type != "object" then error("reactions") else (.["-1"] // 1) > 0 end' <<<"$root")
  if [ "$rollup_says_down" = true ]; then
    down=$(read_array "repos/$REPO/pulls/comments/$rid/reactions" "finding $rid reactions")
    down=$(jqx "finding $rid reactions" -c --arg bot "$BOT" \
      '[ .[] | select(.content == "-1" and (.user.login // "") != $bot) | .created_at ]' <<<"$down")
    if [ "$(jqx "finding $rid reactions" 'length' <<<"$down")" -gt 0 ]; then
      times=$(jqx "finding $rid" -c --argjson d "$down" '. + $d' <<<"$times")
      sources=$(jqx "finding $rid" -c '. + ["thumbs-down"]' <<<"$sources")
    fi
  fi
  if [ "$(jqx "finding $rid" 'length' <<<"$times")" -gt 0 ]; then
    REBUTTALS=$(jqx "rebuttals" -c --argjson r "$root" --argjson t "$times" --argjson s "$sources" \
      '. + [{finding: $r.id, path: ($r.path // null), at: ($t | max), sources: $s}]' <<<"$REBUTTALS")
  fi
done <<<"$(jqx "review comments" -c '.[] | select(.in_reply_to_id == null)' <<<"$BOT_REVIEW_COMMENTS")"

# Review-body findings have no thread, so their disposition is an issue-comment
# acknowledgement, `[mergepath-review-ack: <review-id> <fingerprint>]`
# (review-feedback-accounting.sh). The ack does not say whether the finding was
# fixed or rebutted, so an ack of a Codex review with a BLOCKING body finding is
# read as a rebuttal of that review (path null, dated by the ack's later of
# creation and edit). Over-reading errs toward a human stop, never toward a
# waiver (#1560 canary: body rebuttals never reached the ledger).
printf '%s\n' "$LEDGER_REVIEWS" >"$LEDGER_TMP/ack_reviews.json"
BODY_REBUTTALS=$(jqx "review acks" -c --slurpfile rv "$LEDGER_TMP/ack_reviews.json" --arg bot "$BOT" \
  --argjson required "$REQUIRED_JSON" '
  def blocking_tier($t): $t == "p0" or ($required | index($t)) != null;
  ([ $rv[0][] | select(any(.body_tiers[]; blocking_tier(.))) | .id ]) as $blocking
  | [ .[] | select((.user.login // "") != $bot and ((.user.type // "") != "Bot"))
      | . as $c
      | ((.body // "") | [ scan("\\[mergepath-review-ack:\\s*([0-9]+)\\s+[0-9a-f]+\\]") | .[0] | tonumber ]) as $ids
      | $ids[] | select(. as $i | $blocking | index($i))
      | {finding: ., path: null,
         at: ([$c.created_at, $c.updated_at] | map(select(type == "string")) | max),
         sources: ["review-ack"]} ]
  | group_by(.finding) | map({finding: .[0].finding, path: null, at: (map(.at) | max), sources: ["review-ack"]})' <<<"$ISSUE_COMMENTS")
REBUTTALS=$(jqx "rebuttals" -c --argjson b "$BODY_REBUTTALS" '. + $b' <<<"$REBUTTALS")

# ---- verdicts, reactions, provider blocks, summary ------------------------------
VERDICTS=$(crqe_verdicts "$ISSUE_COMMENTS" "$BOT") || die "cannot parse Codex verdict comments"
VERDICTS=$(jqx "verdicts" -c 'unique_by(.comment_id)' <<<"$VERDICTS")
REACTIONS=$(jqx "issue reactions" -c --arg bot "$BOT" \
  '[.[] | select(.user.login == $bot and .content == "+1") | {id, created_at}] | unique_by(.id)' <<<"$ISSUE_REACTIONS")
BLOCKS='[]'
while IFS= read -r c; do
  [ -n "$c" ] || continue
  m=$(codex_failure_marker_of "$(jqx "bot comment" -r '.body // ""' <<<"$c")")
  [ -n "$m" ] || continue
  BLOCKS=$(jqx "blocks" -c --argjson c "$c" --arg m "$m" \
    '. + [{comment_id: $c.id, created_at: $c.created_at, reason: $m}]' <<<"$BLOCKS")
done <<<"$(jqx "bot comments" -c --arg bot "$BOT" --argjson verdict_ids "$(jqx "verdicts" -c 'map(.comment_id)' <<<"$VERDICTS")" '
  unique_by(.id) | .[] | select(.user.login == $bot)
      # A verdict is never a block notice (codex-review-request.sh precedence),
      # and the mutable Review Summary is current state, not history.
      | select((.id as $i | $verdict_ids | index($i)) | not)
      | select(((.body // "") | startswith("<!-- codex-pull-request-review-summary -->")) | not)' <<<"$ISSUE_COMMENTS")"
SUMMARY_JSON=$(crqe_select_codex_review_summary "$ISSUE_COMMENTS" "$BOT" "$HEAD_SHA") \
  || die "cannot read the Codex Review Summary"

printf '%s\n' "$REQUESTS" >"$LEDGER_TMP/in_requests.json"
printf '%s\n' "$LEDGER_REVIEWS" >"$LEDGER_TMP/in_reviews.json"
printf '%s\n' "$VERDICTS" >"$LEDGER_TMP/in_verdicts.json"
printf '%s\n' "$REACTIONS" >"$LEDGER_TMP/in_reactions.json"
printf '%s\n' "$BLOCKS" >"$LEDGER_TMP/in_blocks.json"
printf '%s\n' "$SUMMARY_JSON" >"$LEDGER_TMP/in_summary.json"
printf '%s\n' "$REBUTTALS" >"$LEDGER_TMP/in_rebuttals.json"
INPUTS=$(jqx "ledger inputs" -n \
  --argjson pr "$PR_NUMBER" --arg repo "$REPO" --arg head "$HEAD_SHA" \
  --arg author "$AUTHOR" --arg bot "$BOT" --argjson required "$REQUIRED_JSON" \
  --slurpfile requests "$LEDGER_TMP/in_requests.json" --slurpfile reviews "$LEDGER_TMP/in_reviews.json" \
  --slurpfile verdicts "$LEDGER_TMP/in_verdicts.json" --slurpfile reactions "$LEDGER_TMP/in_reactions.json" \
  --slurpfile blocks "$LEDGER_TMP/in_blocks.json" --slurpfile summary "$LEDGER_TMP/in_summary.json" \
  --slurpfile rebuttals "$LEDGER_TMP/in_rebuttals.json" \
  '{pr: $pr, repo: $repo, head_sha: $head, author: $author, bot: $bot,
    required_tiers: $required, requests: $requests[0], reviews: $reviews[0],
    verdicts: $verdicts[0], reactions: $reactions[0], blocks: $blocks[0],
    summary: $summary[0], rebuttals: $rebuttals[0]}')
LEDGER=$(crl_ledger "$INPUTS") || die "ledger computation failed"
# The evidence reads above take time; a push that lands during them would
# leave this ledger describing a head the PR no longer has. Re-read the live
# head once every read is done and refuse a moved one.
LIVE_HEAD=$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq '.head.sha' 2>/dev/null) \
  || die "cannot re-read the PR #$PR_NUMBER head after the evidence reads"
[ "$LIVE_HEAD" = "$HEAD_SHA" ] \
  || die "PR #$PR_NUMBER head moved from $HEAD_SHA to $LIVE_HEAD during the ledger reads"
# The blocking-review budget of the policy snapshot this ledger was read
# under, by crqe_governing_budget's rule (absent: 10; not one to nine digits:
# null), so a consumer can refuse a limit read from a different snapshot.
MAX_BLOCKING=$(printf '%s' "$POLICY_JSON" | jq -c '
  (if (has("codex") | not) then "10"
   elif ((.codex | type) != "object") then null
   elif (.codex | has("max_blocking_reviews")) then
     (.codex.max_blocking_reviews | if (type == "string" or type == "number") then tostring else null end)
   else "10" end)
  | if type == "string" and test("^[0-9]{1,9}$") then tonumber else null end') \
  || die "governing codex.max_blocking_reviews does not parse"
LEDGER=$(jqx "ledger" -c --argjson m "$MAX_BLOCKING" --arg fp "$POLICY_FP" \
  '. + {max_blocking_reviews: $m, policy_fingerprint: $fp}' <<<"$LEDGER")

if [ "$SUMMARY" != true ]; then
  printf '%s\n' "$LEDGER"
  exit 0
fi

printf '%s\n' "$LEDGER" | jq -r '
  .summary as $s
  | "\(.repo)#\(.pr)  head \(.head_sha[0:8])  author \(.author)  required tiers \(.required_tiers | join(","))",
    "requests: \($s.requests) counted, \($s.foreign_requests) foreign  (eyes now \($s.eyes_now); re-posted without a response \($s.reposted_without_response): after eyes \($s.reposted_after_eyes), eyes unknown \($s.reposted_eyes_unknown))",
    "counted outcomes: attributed \($s.outcomes.attributed), ambiguous \($s.outcomes.ambiguous), unanswered \($s.outcomes.unanswered), no response yet \($s.outcomes.no_response_yet); open debt \($s.open_debt)",
    "foreign outcomes: attributed \($s.foreign_outcomes.attributed), ambiguous \($s.foreign_outcomes.ambiguous), unanswered \($s.foreign_outcomes.unanswered), no response yet \($s.foreign_outcomes.no_response_yet)",
    "responses: \($s.responses)  (unsolicited \($s.unsolicited_responses), mixed-head windows \($s.mixed_head_windows), multi-response windows \($s.multiple_response_windows), ties \($s.tie_responses), conflicting \($s.conflicting_responses), anchor conflicts \($s.anchor_conflicts))",
    "responses by class: \($s.responses_by_class | to_entries | map("\(.key)=\(.value)") | join(", "))",
    "blocking responses: \($s.blocking_responses)  (solicited \($s.blocking_responses_solicited))",
    "thread-reply review wrappers (not responses): \($s.thread_reply_reviews)",
    ( .requests[] | select(.outcome != "attributed" or .reposted_without_response or (.possible_second_response | length) > 0)
      | "  \(if .counted then "request" else "foreign \(.source)" end) \(.id) @ \(.created_at): \(.outcome)"
        + (if (.reasons | length) > 0 then " (\(.reasons | join("; ")); candidates \(.candidates | map(tostring) | join(",")))" else "" end)
        + (if .reposted_without_response then " [re-posted after \(.repost_gap_seconds)s with no response; eyes before re-post: \(.eyes_before_repost)]" else "" end)
        + (if (.possible_second_response | length) > 0 then " [a later response may also answer this]" else "" end) )'
