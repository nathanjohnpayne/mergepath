#!/usr/bin/env bash
# #1276: real checker, fake provider. Diagnostics must never decide clearance.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/lib/codex-request-evidence.sh
. "$ROOT/scripts/lib/codex-request-evidence.sh"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/scripts/workflow" "$DIR/bin"
cp "$ROOT/scripts/codex-review-check.sh" "$DIR/scripts/"
cp "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" "$DIR/scripts/workflow/"
ln -s "$ROOT/scripts/lib" "$DIR/scripts/lib"
cat >"$DIR/policy.yml" <<'POLICY'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-codex
  - nathanpayne-claude
codex:
  enabled: true
  allow_phase_4b_substitute: false
  reaction_freshness_window_seconds: 999999999
  require_ci_green: false
  review_timeout_seconds: 840
  ack_wait_seconds: 30
POLICY
cp "$DIR/policy.yml" "$DIR/default-policy.yml"
cat >"$DIR/scripts/workflow/external_review_carryforward.sh" <<'CARRY'
#!/usr/bin/env bash
if [ -n "${CARRY_FIXTURE:-}" ]; then printf '%s\n' "$CARRY_FIXTURE"; else echo '{"carried":false}'; fi
CARRY
chmod +x "$DIR/scripts/workflow/external_review_carryforward.sh"
cat >"$DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 99
shift
[ "${1:-}" != --paginate ] || shift
printf '%s\n' "$1" >>"$CALLS"
case "$1" in
  repos/owner/repo/pulls/99) jq -cn --arg body "$PR_BODY" --arg author "$PR_AUTHOR" '{head:{sha:"abcdef0123456789000000000000000000000000"},base:{ref:"main"},user:{login:$author},body:$body,labels:[]}' ;;
  repos/owner/repo/commits/*) [ "${TIMESTAMP_READS_FAIL:-0}" != 1 ] || exit 1; echo '2026-09-14T00:00:00Z' ;;
  repos/owner/repo/issues/99/comments)
    if [ -n "${COMMENTS_FAIL_FROM:-}" ] \
       && [ "$(grep -c '^repos/owner/repo/issues/99/comments$' "$CALLS")" -ge "$COMMENTS_FAIL_FROM" ]; then
      exit 1
    fi
    # #2881: a later read may see newer comment bodies than the first.
    if [ -f "$FIXTURES/comments-reread" ] \
       && [ "$(grep -c '^repos/owner/repo/issues/99/comments$' "$CALLS")" -ge 2 ]; then
      cat "$FIXTURES/comments-reread"; exit 0
    fi
    cat "$FIXTURES/comments" ;;
  repos/owner/repo/pulls/99/reviews) [ "${REVIEWS_FAIL:-0}" != 1 ] || { echo 'fixture review read failed' >&2; exit 1; }
    # #2881: a later read may see newer reviews than the first.
    if [ -f "$FIXTURES/reviews-reread" ] \
       && [ "$(grep -c '^repos/owner/repo/pulls/99/reviews$' "$CALLS")" -ge 2 ]; then
      cat "$FIXTURES/reviews-reread"; exit 0
    fi
    cat "$FIXTURES/reviews" ;;
  repos/owner/repo/pulls/99/files) printf '%s\n' '[]' ;;
  repos/owner/repo/rulesets*) printf '%s\n' '[]' ;;
  repos/owner/repo/rules/branches/main) printf '%s\n' '[]' ;;
  repos/owner/repo/contents/.github/workflows/repo_lint_local.yml*) echo 'HTTP 404: fixture annex absent' >&2; exit 1 ;;
  repos/owner/repo/issues/comments/123/reactions) [ "$ACK_READ" != error ] || exit 1; cat "$FIXTURES/ack" ;;
  repos/owner/repo/issues/comments/124/reactions) cat "$FIXTURES/new-ack" ;;
  repos/owner/repo/issues/99/reactions) printf '%s\n' "$ISSUE_REACTIONS" ;;
  repos/owner/repo/issues/99/timeline) [ "${TIMESTAMP_READS_FAIL:-0}" != 1 ] || exit 1; echo '[]' ;;
  repos/owner/repo/pulls/99/comments) [ "${INLINE_COMMENTS_FAIL:-0}" != 1 ] || exit 1; printf '%s\n' "${INLINE_COMMENTS_JSON:-[]}" ;;
  graphql)
    case "$*" in
      *requiredStatusCheckContexts*) printf '%s\n' '{"data":{"repository":{"isInOrganization":false,"viewerPermission":"WRITE","ref":{"refUpdateRule":{"requiredStatusCheckContexts":["Build"]}}}}}' ;;
      *statusCheckRollup*) printf '%s\n' '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"StatusContext","context":"Build","state":"FAILURE","createdAt":"2026-09-14T00:03:00Z","isRequired":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]}}}}}' ;;
      *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}' ;;
    esac ;;
  *) echo "unexpected $*" >&2; exit 99 ;;
esac
GH
chmod +x "$DIR/bin/gh"
TRIGGER='{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@codex review"}'
LATER_MENTION='{"id":124,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:03:00Z","body":"Status: @codex review was already requested."}'
UPPER_TRIGGER='{"id":124,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:03:00Z","body":"@CODEX REVIEW"}'
UPPER_QUOTE='{"id":125,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:05:00Z","body":"> @CODEX REVIEW"}'
UPPER_PROSE='{"id":126,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:06:00Z","body":"Status: @CODEX REVIEW was already requested."}'
EYES='[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes","created_at":"2026-09-14T00:02:00Z"}]'
# shellcheck disable=SC2016 # Literal Markdown commit cell, not shell substitution.
RUNNING='{"id":456,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:02:00Z","body":"<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | **Running** | `abcdef0` | Manual |"}'
REVIEW='[{"id":789,"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:02:00Z","state":"COMMENTED"}]'
QUOTA='{"id":124,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:01:00Z","body":"You have reached your Codex usage limits for code reviews."}'
PASS=0
# #1635: each empty input must fail without partial anchor output.
threshold_committed=2026-09-14T00:00:00Z
threshold_now=1789345200
for threshold_empty in committed seconds epoch; do
  threshold_date="$threshold_committed"; threshold_seconds=1800; threshold_epoch="$threshold_now"
  case "$threshold_empty" in
    committed) threshold_date='' ;;
    seconds) threshold_seconds='' ;;
    epoch) threshold_epoch='' ;;
  esac
  threshold_rc=0
  crqe_request_threshold "$threshold_date" '[]' "$threshold_seconds" "$threshold_epoch" \
    >"$DIR/threshold.out" 2>"$DIR/threshold.err" || threshold_rc=$?
  if [ "$threshold_rc" = 1 ] && [ ! -s "$DIR/threshold.out" ]; then
    PASS=$((PASS + 1)); echo "PASS: empty threshold $threshold_empty fails with no output"
  else
    echo "FAIL: empty threshold $threshold_empty returned rc=$threshold_rc or output" >&2
    exit 1
  fi
done
# Fixed valid inputs retain the complete byte-level anchor record.
threshold_out=$(crqe_request_threshold "$threshold_committed" '[]' 1800 "$threshold_now") \
  || { echo 'FAIL: valid threshold input was rejected' >&2; exit 1; }
threshold_expected='{"head_pushed_at":"2026-09-14T00:00:00Z","anchor_source":"HEAD committer date","reaction_floor":"2026-09-13T23:50:00Z","reaction_threshold":"2026-09-14T00:00:00Z","reaction_threshold_source":"HEAD pushed-at anchor (HEAD committer date)"}'
if [ "$threshold_out" = "$threshold_expected" ]; then
  PASS=$((PASS + 1)); echo 'PASS: valid threshold anchor output is unchanged'
else
  echo "FAIL: valid threshold anchor output: $threshold_out" >&2
  exit 1
fi

while IFS='|' read -r name comments ack reviews mode opted expected pattern reads selected_trigger; do
  case "$comments" in
    trigger) comments="[$TRIGGER]" ;;
    wrong-id) comments="[${TRIGGER/123/124}]" ;;
    mention-only) comments="[$LATER_MENTION]" ;;
    trigger-then-mention) comments="[$TRIGGER,$LATER_MENTION]" ;;
    lower-then-upper) comments="[$TRIGGER,$UPPER_TRIGGER]" ;;
    upper-then-quote) comments="[$TRIGGER,$UPPER_TRIGGER,$UPPER_QUOTE]" ;;
    upper-then-prose) comments="[$TRIGGER,$UPPER_TRIGGER,$UPPER_PROSE]" ;;
    upper-quote-only) comments="[$UPPER_QUOTE]" ;;
    upper-prose-only) comments="[$UPPER_PROSE]" ;;
    mention-running) comments="[$LATER_MENTION,$RUNNING]" ;;
    future) comments="[${TRIGGER/2026-09-14T00:01:00Z/2077-09-14T00:01:00Z}]" ;;
    stale) comments="[${TRIGGER/2026-09-14T00:01:00Z/2026-09-13T00:01:00Z}]" ;;
    foreign) comments="[${TRIGGER/nathanjohnpayne/nathanpayne-claude}]" ;;
    running) comments="[$RUNNING]" ;;
    completed) comments="[${RUNNING/Running/Completed}]" ;;
    old-block) comments="[$TRIGGER,${QUOTA/2026-09-14T00:01:00Z/2026-09-14T00:00:30Z}]" ;;
    same-second-old-block) comments="[$TRIGGER,${QUOTA/124/122}]" ;;
    current-block) comments="[$TRIGGER,${QUOTA/2026-09-14T00:01:00Z/2026-09-14T00:01:30Z}]" ;;
    same-second-current-block) comments="[$TRIGGER,$QUOTA]" ;;
    running-after-block) comments="[$TRIGGER,$QUOTA,$RUNNING]" ;;
    *) comments='[]' ;;
  esac
  new_ack='[]'
  case "$ack" in
    eyes) ack="$EYES" ;;
    new-eyes) new_ack="${EYES/2026-09-14T00:02:00Z/2026-09-14T00:04:00Z}"; ack='[]' ;;
    foreign) ack="${EYES/chatgpt-codex-connector\[bot\]/someone}" ;;
    *) ack='[]' ;;
  esac
  case "$reviews" in
    review) reviews="$REVIEW" ;;
    approved) reviews='[{"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:02:00Z"}]' ;;
  esac
  printf '%s\n' "$comments" >"$DIR/comments"
  printf '%s\n' "$ack" >"$DIR/ack"
  printf '%s\n' "$new_ack" >"$DIR/new-ack"
  printf '%s\n' "$reviews" >"$DIR/reviews"
  : >"$DIR/calls"
  cp "$DIR/default-policy.yml" "$DIR/policy.yml"
  [ "$name" != unknown-budget ] || sed -i.bak 's/review_timeout_seconds:.*/review_timeout_seconds: unavailable/' "$DIR/policy.yml"
  [ "$name" != default-budgets ] || sed -i.bak '/review_timeout_seconds:/d; /ack_wait_seconds:/d' "$DIR/policy.yml"
  if [ "$name" = uppercase-configured-author ]; then
    sed -i.bak 's/author_identity:.*/author_identity: diagnostic-author/' "$DIR/policy.yml"
    comments="${comments//nathanjohnpayne/diagnostic-author}"
    printf '%s\n' "$comments" >"$DIR/comments"
  fi
  pr_body='Authoring-Agent: codex'; pr_author=nathanjohnpayne; issue_reactions='[]'
  if [ "$name" = rerun ] || [ "$name" = terminal-unapproved ]; then
    # An external contributor has no same-agent approval fallback. Preserve
    # this diagnostic fixture's missing registered-reviewer approval.
    pr_body=''; pr_author=contributor
  fi
  if [ "$name" = thumbs-unapproved ]; then
    pr_body=''; pr_author=contributor; issue_reactions="${EYES/eyes/+1}"
  fi
  case "$name" in
    # #2550: the authoring agent's own approval is discounted, and the
    # message names it and the threshold-aware gate rather than claiming
    # that no approval exists.
    same-agent-*) pr_body='Authoring-Agent: claude' ;;
  esac
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ="$name" \
    PR_BODY="$pr_body" PR_AUTHOR="$pr_author" ISSUE_REACTIONS="$issue_reactions" \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/policy.yml" CODEX_REVIEW_CHECK_REPORT_REQUEST_EVIDENCE="$opted" \
    bash "$DIR/scripts/codex-review-check.sh" ${mode:+"$mode"} 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ] || ! grep -q "$pattern" "$DIR/out"; then
    cat "$DIR/out"; echo "FAIL $name rc=$rc"; exit 1
  fi
  if [ "$name" = trigger-then-mention ]; then
    if ! grep -q 'freshness-qualified author trigger #123 at 2026-09-14T00:01:00Z' "$DIR/out" \
      || grep -q 'freshness-qualified author trigger #124' "$DIR/out"; then
      cat "$DIR/out"; echo 'FAIL trigger-then-mention did not bind exact request #123'; exit 1
    fi
  fi
  # #1430: the newest complete command owns both its diagnostic and the
  # acknowledgement read; older request eyes cannot be borrowed.
  if [ -n "$selected_trigger" ]; then
    if ! grep -Fq "freshness-qualified author trigger #$selected_trigger at" "$DIR/out" \
       || ! grep -Fxq "repos/owner/repo/issues/comments/$selected_trigger/reactions" "$DIR/calls"; then
      cat "$DIR/out"; echo "FAIL $name did not select request #$selected_trigger and its acknowledgement"; exit 1
    fi
  fi
  if [ "$name" = requested ]; then
    if ! grep -Eq 'age=[0-9]+s; configured ack_wait_seconds=30; review_timeout_seconds=840' "$DIR/out"; then
      echo 'FAIL requested case missing age/ack-wait/timeout diagnostic:'
      cat "$DIR/out"
      exit 1
    fi
    if ! grep -q 'not immutable SHA attribution' "$DIR/out"; then
      echo 'FAIL requested case missing immutable-SHA attribution diagnostic:'
      cat "$DIR/out"
      exit 1
    fi
  fi
  case "$name" in
    completed-*)
      if grep -q 'monitor provider progress' "$DIR/out"; then
        cat "$DIR/out"; echo "FAIL $name advised monitoring a completed review"; exit 1
      fi ;;
    thumbs-unapproved)
      if grep -Eq 'no matching provider activity|request review through' "$DIR/out"; then
        cat "$DIR/out"; echo 'FAIL thumbs-unapproved gave unsupported review advice'; exit 1
      fi
      if grep -q '/issues/99/reactions' "$DIR/calls"; then
        cat "$DIR/calls"; echo 'FAIL thumbs-unapproved read issue reactions'; exit 1
      fi ;;
  esac
  actual=$(grep -c '/issues/comments/' "$DIR/calls" || true)
  [ "$actual" = "$reads" ] || { echo "FAIL $name ack reads=$actual"; exit 1; }
  if [ "$opted" = 0 ] || [ -n "$mode" ]; then
    ! grep -q 'request evidence' "$DIR/out" || { echo "FAIL $name changed query/ordinary output"; exit 1; }
  fi
  PASS=$((PASS + 1))
  echo "PASS: $name"
done <<'CASES'
missing|none|none|[]||1|1|no freshness-qualified author trigger|0
requested|trigger|eyes|[]||1|1|linked eyes acknowledgement=true|1
uppercase-own-ack|lower-then-upper|new-eyes|[]||1|1|linked eyes acknowledgement=true|1|124
uppercase-old-ack|lower-then-upper|eyes|[]||1|1|linked eyes acknowledgement=false|1|124
uppercase-configured-author|lower-then-upper|new-eyes|[]||1|1|linked eyes acknowledgement=true|1|124
uppercase-then-quote|upper-then-quote|new-eyes|[]||1|1|linked eyes acknowledgement=true|1|124
uppercase-then-prose|upper-then-prose|new-eyes|[]||1|1|linked eyes acknowledgement=true|1|124
uppercase-quote-only|upper-quote-only|new-eyes|[]||1|1|no freshness-qualified author trigger|0
uppercase-prose-only|upper-prose-only|new-eyes|[]||1|1|no freshness-qualified author trigger|0
no-ack|trigger|none|[]||1|1|linked eyes acknowledgement=false|1
wrong-comment|wrong-id|eyes|[]||1|1|linked eyes acknowledgement=false|1
mention-only|mention-only|eyes|[]||1|1|no freshness-qualified author trigger|0
mention-running|mention-running|eyes|[]||1|1|current-head running summary observed.*monitor provider progress|0
trigger-then-mention|trigger-then-mention|eyes|[]||1|1|linked eyes acknowledgement=true|1
foreign-ack|trigger|foreign|[]||1|1|linked eyes acknowledgement=false|1
error|trigger|none|[]||1|1|linked eyes acknowledgement=unknown|1
unknown-budget|trigger|none|[]||1|1|review_timeout_seconds=unknown|1
default-budgets|trigger|none|[]||1|1|configured ack_wait_seconds=30; review_timeout_seconds=1800|1
future-request|future|none|[]||1|1|age=unknowns|1
old-request|stale|eyes|[]||1|1|no freshness-qualified author trigger|0
foreign-request|foreign|eyes|[]||1|1|no freshness-qualified author trigger|0
provider-only|running|none|[]||1|1|current-head running summary observed.*monitor provider progress|0
rerun|running|none|review||1|1|current-head running summary observed.*monitor provider progress|0
terminal-unapproved|none|none|review||1|1|current-head terminal artifact observed|0
completed-unapproved|completed|none|[]||1|1|completed summary observed.*inspect the unmet clearance requirement|0
completed-gate-c|completed|none|approved||1|1|completed summary observed.*inspect the unmet clearance requirement|0
thumbs-unapproved|none|none|[]||1|1|no freshness-qualified author trigger|0
gate-c|trigger|eyes|approved||1|1|linked eyes acknowledgement=true|1
not-opted|trigger|eyes|[]||0|1|no reviewer identity|0
same-agent-approved|none|none|approved||0|1|no qualifying reviewer approval cleared gate (b): the latest-state APPROVED review from the authoring agent.s own reviewer identity (nathanpayne-claude) is discounted.*run scripts/merge-clearance-gate.sh.*--require-codex-on-head|0
same-agent-unapproved|none|none|[]||0|1|no reviewer identity in available_reviewers has a latest-state APPROVED review, and same-agent|0
readiness|trigger|eyes|[]|--approval-readiness-only|1|1|no reviewer identity|0
diagnostic|trigger|eyes|[]|--diagnostic-signal-only|1|1|Codex has not produced|0
renewed-provider-block|old-block|none|[]|--require-codex-on-head|0|1|no reviewer identity|0
same-second-prior-block|same-second-old-block|none|[]|--require-codex-on-head|0|1|no reviewer identity|0
current-provider-block|current-block|none|[]|--require-codex-on-head|0|2|human_attention_required|0
same-second-current-block|same-second-current-block|none|[]|--require-codex-on-head|0|2|human_attention_required|0
running-after-provider-block|running-after-block|none|[]|--diagnostic-signal-only|0|1|Codex review summary is Running|0
CASES

# #2337: both live callers use the same request-ordering predicate.
block='{"reason":"usage_limit","created_at":"2026-09-14T00:01:00Z","comment_id":124}'
request='{"created_at":"2026-09-14T00:01:00Z","id":123}'
[ "$(crqe_filter_provider_block "$block" "$request")" != null ]
[ "$(crqe_filter_provider_block "$block" "${request/123/125}")" = null ]
[ "$(crqe_filter_provider_block "$block" "${request/00:01:00Z/00:02:00Z}")" = null ]
[ "$(crqe_filter_provider_block "$block" "${request/00:01:00Z/00:00:00Z}")" != null ]
for status in running unknown; do
  summary=$(jq -nc --arg status "$status" '{status:$status,observed_at:"2026-09-14T00:02:00Z"}')
  [ "$(crqe_filter_provider_block "$block" "$request" "$summary")" = null ]
done
[ "$(crqe_filter_provider_block "$block" null)" != null ]
rc=0; result=$(crqe_filter_provider_block "$block" '{"created_at":"2026-09-14T00:01:00Z"}' 2>/dev/null) || rc=$?
[ "$rc" != 0 ] && [ -z "$result" ] || { echo 'FAIL: unreadable same-second request ordering became absence'; exit 1; }
PASS=$((PASS + 8)); echo 'PASS: provider refusals bind request IDs/time and preserve newer active/unknown holds'
# The existing carry-forward remains eligible and successful, without ack reads.
# No author request is newer than the carried verdict here; a newer one would
# supersede it until Codex answers (#1598, covered below).
printf '[]\n' >"$DIR/comments"
CARRY_FIXTURE='{"carried":true,"source_time":"2026-09-14T00:00:00Z","source_commit":"oldhead","fingerprint":"same"}' \
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=error \
  PR_BODY='Authoring-Agent: codex' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/policy.yml" CODEX_REVIEW_CHECK_REPORT_REQUEST_EVIDENCE=1 \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || { cat "$DIR/out"; exit 1; }
if grep -q 'request evidence' "$DIR/out"; then echo 'FAIL: diagnostic on success'; exit 1; fi
carry_forward_api_calls=$(grep -c '/issues/comments/' "$DIR/calls" || true)
if [ "$carry_forward_api_calls" != 0 ]; then
  echo "FAIL carry-forward expected zero issue-comment API calls, got $carry_forward_api_calls:"
  cat "$DIR/calls"
  exit 1
fi

# The count and authority fence share one exact-command generation selector.
# It is ID-stable, case-insensitive for the complete command, de-duplicates a
# repeated page item, ignores mentions/foreign authors, and rejects malformed
# qualifying IDs instead of silently shrinking the generation.
GENERATION_FIXTURE='[
  {"id":125,"user":{"login":"nathanjohnpayne"},"body":"@CODEX REVIEW"},
  {"id":123,"user":{"login":"nathanjohnpayne"},"body":"@codex review"},
  {"id":125,"user":{"login":"nathanjohnpayne"},"body":"@CODEX REVIEW"},
  {"id":124,"user":{"login":"nathanjohnpayne"},"body":"status: @codex review"},
  {"id":126,"user":{"login":"someone-else"},"body":"@codex review"}
]'
[ "$(crqe_trigger_generation "$GENERATION_FIXTURE" nathanjohnpayne)" = '[123,125]' ]
[ "$(crqe_count_triggers "$GENERATION_FIXTURE" nathanjohnpayne)" = 2 ]
if crqe_trigger_generation '[{"id":"bad","user":{"login":"nathanjohnpayne"},"body":"@codex review"}]' nathanjohnpayne >/dev/null 2>&1; then
  echo "FAIL: malformed qualifying request ID was accepted" >&2
  exit 1
fi
echo "PASS: shared exact-request generation selector"

# #2534: a CodeRabbit rate-limit failover request does not spend the request
# ceiling. Only a marker posted by the requester itself, right after its own
# trigger, exempts that trigger; every forgery or stretch below leaves it
# counted, and the trigger always stays in the generation.
fo_c() { # <id> <login> <created> <body> [updated]
  jq -nc --argjson id "$1" --arg u "$2" --arg c "$3" --arg b "$4" --arg up "${5:-$3}" \
    '{id: $id, user: {login: $u}, created_at: $c, updated_at: $up, body: $b}'
}
FO_HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FO_HB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fo_m() { crqe_failover_marker_body "${2:-$FO_HA}" "$1"; }
# The PR's heads (#2553): a marker must name one of them.
FO_HEADS=$(jq -nc --arg a "$FO_HA" --arg b "$FO_HB" '[$a, $b]')
fo_case() { # <name> <expected-exempt-json> <expected-count> <comment>...   (FO_CASE_HEADS overrides the heads)
  local name=$1 want=$2 count=$3 c got n
  shift 3
  c=$(printf '%s\n' "$@" | jq -sc .)
  got=$(crqe_failover_trigger_ids "$c" nathanjohnpayne "${FO_CASE_HEADS:-$FO_HEADS}") \
    && n=$(crqe_count_triggers "$c" nathanjohnpayne "${FO_CASE_HEADS:-$FO_HEADS}") \
    && [ "$got" = "$want" ] && [ "$n" = "$count" ] \
    || { echo "FAIL: failover: $name (exempt=$got count=${n:-?}, want $want/$count)" >&2; exit 1; }
}
T1=$(fo_c 10 nathanjohnpayne 2026-10-01T00:00:00Z '@codex review')
T2=$(fo_c 20 nathanjohnpayne 2026-10-01T01:00:00Z '@codex review')
fo_case "no marker counts every request" '[]' 2 "$T1" "$T2"
fo_case "a marker right after its trigger exempts it" '[10]' 1 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" "$T2"
fo_case "a marker 300 s after is still in the window" '[10]' 1 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:05:00Z "$(fo_m 10)")" "$T2"
fo_case "a marker added later cannot exempt an old request" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:05:01Z "$(fo_m 10)")" "$T2"
fo_case "a marker by another login" '[]' 2 "$T1" "$(fo_c 11 nathanpayne-claude 2026-10-01T00:00:05Z "$(fo_m 10)")" "$T2"
fo_case "an edited marker" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)" 2026-10-01T00:00:09Z)" "$T2"
fo_case "a marker naming a comment that is not a request" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 9)")" "$T2"
fo_case "a marker naming a foreign request" '[]' 2 "$T1" "$(fo_c 9 someone-else 2026-10-01T00:00:01Z '@codex review')" \
  "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 9)")" "$T2"
fo_case "a marker with another request between it and its trigger" '[]' 3 "$T1" \
  "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:02Z '@codex review')" "$(fo_c 12 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" "$T2"
fo_case "a marker that is not the whole body" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "> $(fo_m 10)")" \
  "$(fo_c 12 nathanjohnpayne 2026-10-01T00:00:06Z "$(fo_m 10) extra")" "$T2"
fo_case "an unknown marker version" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10 | sed 's/:v1 /:v2 /')")" "$T2"
fo_case "a marker older than its trigger" '[]' 2 "$(fo_c 11 nathanjohnpayne 2026-09-30T23:59:59Z "$(fo_m 12)")" \
  "$(fo_c 12 nathanjohnpayne 2026-10-01T00:00:00Z '@codex review')" "$T2"
fo_case "one exemption per head" '[10]' 1 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" \
  "$T2" "$(fo_c 21 nathanjohnpayne 2026-10-01T01:00:05Z "$(fo_m 20)")"
fo_case "one exemption on each of two heads" '[10,20]' 0 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" \
  "$T2" "$(fo_c 21 nathanjohnpayne 2026-10-01T01:00:05Z "$(fo_m 20 "$FO_HB")")"
# #2553: a marker naming a head the PR never had exempts nothing, so one
# marker per invented head cannot exempt every trigger.
FO_HX=1111111111111111111111111111111111111111
FO_HY=2222222222222222222222222222222222222222
fo_case "a marker naming a foreign head" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10 "$FO_HX")")" "$T2"
fo_case "one marker per invented head" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10 "$FO_HX")")" \
  "$T2" "$(fo_c 21 nathanjohnpayne 2026-10-01T01:00:05Z "$(fo_m 20 "$FO_HY")")"
fo_case "a real head and an invented one" '[10]' 1 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" \
  "$T2" "$(fo_c 21 nathanjohnpayne 2026-10-01T01:00:05Z "$(fo_m 20 "$FO_HY")")"
FO_CASE_HEADS='[]' fo_case "an empty head set" '[]' 2 "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" "$T2"
_fo_c=$(printf '%s\n' "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" | jq -sc .)
[ "$(crqe_failover_trigger_ids "$_fo_c" nathanjohnpayne)" = '[]' ] && [ "$(crqe_count_triggers "$_fo_c" nathanjohnpayne)" = 1 ] \
  || { echo "FAIL: failover: callers that pass no head set must exempt nothing" >&2; exit 1; }
crqe_failover_markers_present "$_fo_c" nathanjohnpayne && ! crqe_failover_markers_present "$_fo_c" someone-else \
  && ! crqe_failover_markers_present "$(printf '%s\n' "$T1" | jq -sc .)" nathanjohnpayne \
  || { echo "FAIL: failover: marker presence is misread" >&2; exit 1; }
# The head set: the current head, the commit list, committed events and both
# sides of a force-push; anything malformed fails so the caller uses [].
_hs=$(crqe_pr_head_set "$(jq -nc --arg b "$FO_HB" '[{sha: $b}, {sha: "short"}]')" \
  "$(jq -nc --arg x "$FO_HX" --arg y "$FO_HY" --arg c 3333333333333333333333333333333333333333 \
     '[{event: "committed", sha: $c}, {event: "head_ref_force_pushed", commit_id: $y}, {event: "committed", sha: $x}, {event: "labeled", sha: "4444444444444444444444444444444444444444"}]')" \
  "$(printf '%s' "$FO_HA" | tr a-f A-F)")
[ "$_hs" = "$(jq -nc --arg a "$FO_HA" --arg b "$FO_HB" --arg x "$FO_HX" --arg y "$FO_HY" '[$a, $b, $x, $y, "3333333333333333333333333333333333333333"] | sort')" ] \
  || { echo "FAIL: failover: head set was $_hs" >&2; exit 1; }
! crqe_pr_head_set '{"not":"array"}' '[]' "$FO_HA" >/dev/null && ! crqe_pr_head_set '[]' '[]' abc >/dev/null \
  || { echo "FAIL: failover: a malformed head-set input was accepted" >&2; exit 1; }
[ "$(crqe_trigger_generation "$(printf '%s\n' "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10)")" | jq -sc .)" nathanjohnpayne)" = '[10]' ] \
  || { echo "FAIL: failover: an exempt trigger left the request generation" >&2; exit 1; }
! crqe_failover_marker_body abc 10 >/dev/null && ! crqe_failover_marker_body "$FO_HA" 0 >/dev/null \
  || { echo "FAIL: failover: a marker was built from an abbreviated head or a zero id" >&2; exit 1; }
# #2591: a force-push's before and after commits come from GraphQL, because the
# REST event names neither; they join the head set as a fourth input.
FO_HZ=5555555555555555555555555555555555555555
[ "$(crqe_pr_head_set '[]' '[]' "$FO_HA" "$(jq -nc --arg z "$FO_HZ" '[$z, "short", null]')")" = "$(jq -nc --arg a "$FO_HA" --arg z "$FO_HZ" '[$a, $z] | sort')" ] \
  || { echo "FAIL: failover: force-push heads were not added to the head set" >&2; exit 1; }
! crqe_pr_head_set '[]' '[]' "$FO_HA" '{"not":"array"}' >/dev/null \
  || { echo "FAIL: failover: a malformed force-push head list was accepted" >&2; exit 1; }
_fo_mark_z=$(printf '%s\n' "$T1" "$(fo_c 11 nathanjohnpayne 2026-10-01T00:00:05Z "$(fo_m 10 "$FO_HZ")")" | jq -sc .)
[ "$(crqe_failover_trigger_ids "$_fo_mark_z" nathanjohnpayne "$(crqe_pr_head_set '[]' '[]' "$FO_HA" "[\"$FO_HZ\"]")")" = '[10]' ] \
  && [ "$(crqe_failover_trigger_ids "$_fo_mark_z" nathanjohnpayne "$(crqe_pr_head_set '[]' '[]' "$FO_HA")")" = '[]' ] \
  || { echo "FAIL: failover: a marker on a force-pushed-away head must count only with the GraphQL heads" >&2; exit 1; }
# #2600 BEGIN: keep every unbounded history off external command argv.
# The shell-function shim reproduces Linux's per-argument limit on other OSes.
(
  jq() {
    local argument
    for argument in "$@"; do
      if [ "${#argument}" -ge 131072 ]; then
        return 91
      fi
    done
    command jq "$@"
  }
  hs_commits=$(jq -nc --arg h "$FO_HB" '[range(0;4000) | {sha:$h}]')
  hs_timeline=$(jq -nc --arg h "$FO_HY" '[{event:"committed",sha:$h}, {event:"commented",body:("x" * 150000)}]')
  hs_force=$(jq -nc --arg h "$FO_HZ" '[range(0;4000) | $h]')
  hs_expected=$(jq -nc --arg a "$FO_HA" --arg b "$FO_HB" --arg y "$FO_HY" --arg z "$FO_HZ" '[$a,$b,$y,$z] | sort')
  # Prove the limit shim is live without executing an oversized argv.
  if jq -n --argjson c "$hs_commits" '$c' >/dev/null; then
    echo "FAIL: head set argument-limit control did not reject oversized argv" >&2
    exit 1
  fi
  hs_actual=$(crqe_pr_head_set "$hs_commits" "$hs_timeline" "$FO_HA" "$hs_force") \
    && [ "$hs_actual" = "$hs_expected" ] \
    || { echo "FAIL: oversized histories lost PR heads" >&2; exit 1; }
  # Each document must independently be exactly one array. Do not combine
  # documents and let an empty input compensate for an adjacent extra one.
  for hs_bad in '' '[] []' 'null' '{}' '["unterminated' '[] garbage'; do
    for hs_slot in commits timeline force; do
      hs_c='[]'; hs_t='[]'; hs_f='[]'
      case "$hs_slot" in
        commits) hs_c=$hs_bad ;;
        timeline) hs_t=$hs_bad ;;
        force) hs_f=$hs_bad ;;
      esac
      if crqe_pr_head_set "$hs_c" "$hs_t" "$FO_HA" "$hs_f" >"$DIR/head-set-invalid"; then
        echo "FAIL: head set accepted malformed $hs_slot input" >&2
        exit 1
      fi
      [ ! -s "$DIR/head-set-invalid" ] \
        || { echo "FAIL: malformed head set emitted partial output" >&2; exit 1; }
    done
  done
  if crqe_pr_head_set '[] []' '' "$FO_HA" '[]' >"$DIR/head-set-invalid" \
     || crqe_pr_head_set '[' ']' "$FO_HA" '[]' >"$DIR/head-set-invalid"; then
    echo "FAIL: head set accepted cross-input document compensation" >&2
    exit 1
  fi
  [ ! -s "$DIR/head-set-invalid" ] || exit 1
)
echo "PASS: oversized PR histories stream independently and malformed documents fail closed (#2600)"
# #2600 END

# crqe_force_push_heads reads every page through gh's GraphQL pagination,
# which needs the $endCursor variable, and fails on a failed or shapeless read.
FP_DIR=$(mktemp -d)
cat >"$FP_DIR/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FP_LOG"
[ "${FP_MODE:-ok}" != fail ] || exit 1
if [ "${FP_MODE:-ok}" = shapeless ]; then printf '{"data":{"repository":null}}\n'; exit 0; fi
printf '%s\n' '{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"beforeCommit":{"oid":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},"afterCommit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}}}}}'
printf '%s\n' '{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[{"beforeCommit":{"oid":"cccccccccccccccccccccccccccccccccccccccc"},"afterCommit":null},{}]}}}}}'
GH
chmod +x "$FP_DIR/gh"
_fp=$(PATH="$FP_DIR:$PATH" FP_LOG="$FP_DIR/log" crqe_force_push_heads owner/repo 7)
[ "$_fp" = '["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","cccccccccccccccccccccccccccccccccccccccc"]' ] \
  || { echo "FAIL: failover: force-push heads across pages were $_fp" >&2; exit 1; }
grep -q -- '--paginate' "$FP_DIR/log" && grep -q 'endCursor' "$FP_DIR/log" && grep -q 'owner=owner' "$FP_DIR/log" \
  && grep -q 'name=repo' "$FP_DIR/log" && grep -q 'number=7' "$FP_DIR/log" \
  || { echo "FAIL: failover: the force-push read is not a paginated query for owner/repo#7: $(cat "$FP_DIR/log")" >&2; exit 1; }
for _m in fail shapeless; do
  if PATH="$FP_DIR:$PATH" FP_LOG="$FP_DIR/log" FP_MODE=$_m crqe_force_push_heads owner/repo 7 >/dev/null; then
    echo "FAIL: failover: a $_m force-push read was accepted" >&2; exit 1
  fi
done
rm -rf "$FP_DIR"
echo "PASS: failover markers exempt only the requester's own just-posted trigger, on a head the PR had, force-pushed heads included (#2534, #2553, #2591)"

# #1598: a Codex request the configured author posts AFTER a Phase 4b
# substitute approval supersedes it, so gate (c) does not clear on that
# approval until Codex answers. An older request, a newer request from another
# login and a newer mention all leave the approval effective; a qualifying
# request without a timestamp fails closed.
_latest=$(crqe_latest_trigger_time '[{"id":1,"user":{"login":"someone-else"},"created_at":"2026-09-14T00:09:00Z","body":"@codex review"}]' nathanjohnpayne) \
  && [ "$_latest" = "" ] || { echo 'FAIL: no qualifying author request must read as empty, not fail'; exit 1; }
_latest=$(crqe_latest_trigger_time '[{"id":1,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@CODEX REVIEW"},{"id":2,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:03:00Z","body":"@codex review"}]' nathanjohnpayne) \
  && [ "$_latest" = 2026-09-14T00:03:00Z ] || { echo "FAIL: latest author request time was '$_latest'"; exit 1; }
! crqe_latest_trigger_time '[{"id":1,"user":{"login":"nathanjohnpayne"},"body":"@codex review"}]' nathanjohnpayne >/dev/null 2>&1 \
  || { echo 'FAIL: a qualifying request without created_at did not fail closed'; exit 1; }
sed 's/allow_phase_4b_substitute: false/allow_phase_4b_substitute: true/' "$DIR/default-policy.yml" >"$DIR/substitute-policy.yml"
SUB_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:05:00Z"}]'
while IFS='|' read -r name comments expected pattern; do
  printf '%s\n' "$comments" >"$DIR/comments"
  printf '%s\n' "$SUB_APPROVAL" >"$DIR/reviews"
  printf '[]\n' >"$DIR/ack"
  : >"$DIR/calls"
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ="$name" \
    PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ] || ! grep -q "$pattern" "$DIR/out"; then
    cat "$DIR/out"; echo "FAIL #1598 $name rc=$rc"; exit 1
  fi
  PASS=$((PASS + 1))
  echo "PASS: #1598 $name"
done <<'CASES'
older-request|[{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@codex review"}]|0|cleared — Phase 4b substitute
newer-request|[{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:09:00Z","body":"@codex review"}]|1|a Codex request by nathanjohnpayne @ 2026-09-14T00:09:00Z is not older than it (no recorded request generation)
same-second-request|[{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:05:00Z","body":"@codex review"}]|1|a Codex request by nathanjohnpayne @ 2026-09-14T00:05:00Z is not older than it (no recorded request generation)
newer-foreign-request|[{"id":123,"user":{"login":"someone-else"},"created_at":"2026-09-14T00:09:00Z","body":"@codex review"}]|0|cleared — Phase 4b substitute
newer-mention|[{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:09:00Z","body":"status: @codex review was requested"}]|0|cleared — Phase 4b substitute
malformed-request|[{"id":123,"user":{"login":"nathanjohnpayne"},"body":"@codex review"}]|1|Codex request evidence unreadable (#1598)
CASES
# #1598's exact acceptance case: a request (#124, 00:04) lands during the
# final feedback-accounting read, BEFORE the approval is posted (00:05), and
# Codex has not answered it. The approval records the request generation it
# was authorized under ([123]); #124 is outside it, so the approval must not
# clear gate (c) although the request is OLDER than the approval.
RACE_COMMENTS='[{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@codex review"},{"id":124,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:04:00Z","body":"@codex review"}]'
RACE_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:05:00Z","body":"Automated Phase 4b review\n<!-- mergepath-p4b-request-generation: [123] -->"}]'
COVERED_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:05:00Z","body":"Automated Phase 4b review\n<!-- mergepath-p4b-request-generation: [123,124] -->"}]'
# Two markers (e.g. a writer record plus a copy in reviewer-controlled text)
# are ambiguous: fail closed rather than trust either (Codex on #1599 round 4).
DUP_RECORD_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:05:00Z","body":"<!-- mergepath-p4b-request-generation: [123,124] -->\n<!-- mergepath-p4b-request-generation: [123,124] -->"}]'
INVALID_RECORD_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:05:00Z","body":"Automated Phase 4b review\n<!-- mergepath-p4b-request-generation: [123,\"x\"] -->"}]'
while IFS='|' read -r name reviews expected pattern; do
  printf '%s\n' "$RACE_COMMENTS" >"$DIR/comments"
  printf '%s\n' "$reviews" >"$DIR/reviews"
  printf '[]\n' >"$DIR/ack"
  : >"$DIR/calls"
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ="$name" \
    PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ] || ! grep -q "$pattern" "$DIR/out"; then
    cat "$DIR/out"; echo "FAIL #1598 $name rc=$rc"; exit 1
  fi
  # The supersession check re-reads the comments after the reviews read.
  _comment_reads=$(grep -c '^repos/owner/repo/issues/99/comments$' "$DIR/calls" || true)
  [ "$_comment_reads" -ge 2 ] || { cat "$DIR/calls"; echo "FAIL #1598 $name read comments $_comment_reads time(s)"; exit 1; }
  PASS=$((PASS + 1))
  echo "PASS: #1598 $name"
done <<CASES
request-during-final-accounting|$RACE_APPROVAL|1|outside the request generation the approval reviewed
reviewed-generation-covers-request|$COVERED_APPROVAL|0|cleared — Phase 4b substitute
invalid-generation-record|$INVALID_RECORD_APPROVAL|1|its recorded request generation is unreadable
duplicate-generation-record|$DUP_RECORD_APPROVAL|1|not exactly one record
CASES
# #1619: malformed writer records must not become absent/manual records.
# Both requests predate approval, so the timestamp fallback would wrongly
# clear every damaged record. Exercise the production checker, not a copied
# parser, with genuinely absent and valid records as positive controls.
while IFS='|' read -r name body comments expected; do
  printf '%s\n' "$comments" >"$DIR/comments"
  printf '%s\n' "$COVERED_APPROVAL" | jq --arg body "$body" '.[0].body=$body' >"$DIR/reviews"
  : >"$DIR/calls"
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ="$name" \
    PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  pattern='its recorded request generation is unreadable or not exactly one record'
  [ "$expected" != 0 ] || pattern='cleared — Phase 4b substitute'
  if [ "$rc" != "$expected" ] || ! grep -q "$pattern" "$DIR/out"; then
    cat "$DIR/out"; echo "FAIL #1619 $name rc=$rc"; exit 1
  fi
  PASS=$((PASS + 1))
  echo "PASS: #1619 $name"
done <<CASES
missing-closing-space|<!-- mergepath-p4b-request-generation: [123]-->|$RACE_COMMENTS|1
unterminated-record|<!-- mergepath-p4b-request-generation: [123]|$RACE_COMMENTS|1
missing-opening-space|<!-- mergepath-p4b-request-generation:[123] -->|$RACE_COMMENTS|1
missing-colon|<!-- mergepath-p4b-request-generation [123] -->|$RACE_COMMENTS|1
invalid-json|<!-- mergepath-p4b-request-generation: [123,] -->|$RACE_COMMENTS|1
non-array-json|<!-- mergepath-p4b-request-generation: 123 -->|$RACE_COMMENTS|1
non-numeric-id|<!-- mergepath-p4b-request-generation: ["123"] -->|$RACE_COMMENTS|1
valid-plus-malformed|<!-- mergepath-p4b-request-generation: [123,124] --><!-- mergepath-p4b-request-generation: [123]-->|$RACE_COMMENTS|1
malformed-plus-valid|<!-- mergepath-p4b-request-generation: [123]--><!-- mergepath-p4b-request-generation: [123,124] -->|$RACE_COMMENTS|1
valid-plus-unterminated|<!-- mergepath-p4b-request-generation: [123,124] --><!-- mergepath-p4b-request-generation: [123]|$RACE_COMMENTS|1
duplicate-valid-record|<!-- mergepath-p4b-request-generation: [123,124] --><!-- mergepath-p4b-request-generation: [123,124] -->|$RACE_COMMENTS|1
manual-absent-record|Manual Phase 4b approval|$RACE_COMMENTS|0
valid-covered-record|<!-- mergepath-p4b-request-generation: [123,124] -->|$RACE_COMMENTS|0
valid-empty-record|<!-- mergepath-p4b-request-generation: [] -->|[]|0
CASES

# The supersession re-read failing rejects the candidate (fails closed).
printf '%s\n' "$RACE_COMMENTS" >"$DIR/comments"
printf '%s\n' "$COVERED_APPROVAL" >"$DIR/reviews"
: >"$DIR/calls"
rc=0
PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=reread-fails COMMENTS_FAIL_FROM=2 \
  PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
if [ "$rc" = 0 ] || ! grep -q 'Codex request evidence could not be re-read' "$DIR/out"; then
  cat "$DIR/out"; echo "FAIL #1598 reread-fails rc=$rc"; exit 1
fi
PASS=$((PASS + 1))
echo "PASS: #1598 reread-fails"
# #1598 / Codex round 6 on #1599: an EARLIER clean Codex clearance of the
# same head must not clear gate (c) once the configured author has a newer
# request Codex has not answered. Otherwise the earlier clearance supplies
# gate (c) while a stale Phase 4b approval (recorded generation [123], new
# request #124 landing during final accounting) supplies gate (b). Each
# anchored clearance forms are covered; unanchored thumbs never clear,
# an affirmative verdict comment and a carried-forward verdict. Codex
# answering the newer request (a later review) clears again.
SUP_REQ123='{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@codex review"}'
SUP_REQ124='{"id":124,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:04:00Z","body":"@codex review"}'
SUP_VERDICT='{"id":130,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:02:00Z","body":"Codex Review: Didn'"'"'t find any major issues.\n\nReviewed commit: `abcdef0123456789000000000000000000000000`"}'
SUP_STALE_4B='{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:05:00Z","body":"<!-- mergepath-p4b-request-generation: [123] -->"}'
SUP_CODEX_REVIEW='{"id":789,"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:02:00Z","state":"COMMENTED","body":""}'
SUP_CODEX_REVIEW_LATER='{"id":790,"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":"abcdef0123456789000000000000000000000000","submitted_at":"2026-09-14T00:07:00Z","state":"COMMENTED","body":""}'
SUP_THUMBS='[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-09-14T00:02:00Z"}]'
SUP_THUMBS_LATER='[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-09-14T00:02:00Z"},{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-09-14T00:07:00Z"}]'
SUP_VERDICT_LATER='{"id":131,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:07:00Z","body":"Codex Review: Didn'"'"'t find any major issues.\n\nReviewed commit: `abcdef0123456789000000000000000000000000`"}'
SUP_REQ_NO_TIME='{"id":125,"user":{"login":"nathanjohnpayne"},"body":"@codex review"}'
while IFS='|' read -r name comments reviews reactions carry expected pattern; do
  printf '%s\n' "$comments" >"$DIR/comments"
  printf '%s\n' "$reviews" >"$DIR/reviews"
  printf '[]\n' >"$DIR/ack"
  : >"$DIR/calls"
  rc=0
  CARRY_FIXTURE="$carry" PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ="$name" \
    PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS="$reactions" \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ] || ! grep -q "$pattern" "$DIR/out"; then
    cat "$DIR/out"; echo "FAIL #1598 $name rc=$rc"; exit 1
  fi
  PASS=$((PASS + 1))
  echo "PASS: #1598 $name"
done <<CASES
review-then-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_CODEX_REVIEW,$SUP_STALE_4B]|[]||1|Codex clearance @ 2026-09-14T00:02:00Z is superseded
thumbs-then-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|$SUP_THUMBS||1|Codex has not cleared current HEAD
verdict-then-newer-request|[$SUP_REQ123,$SUP_VERDICT,$SUP_REQ124]|[$SUP_STALE_4B]|[]||1|Codex clearance @ 2026-09-14T00:02:00Z is superseded
carry-then-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|[]|{"carried":true,"source_time":"2026-09-14T00:02:00Z","source_commit":"oldhead","fingerprint":"same"}|1|Codex clearance @ 2026-09-14T00:02:00Z is superseded
review-older-request-still-clears|[$SUP_REQ123]|[$SUP_CODEX_REVIEW,$SUP_STALE_4B]|[]||0|latest Codex signal is COMMENTED review @ 2026-09-14T00:02:00Z
codex-answers-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_CODEX_REVIEW,$SUP_STALE_4B,$SUP_CODEX_REVIEW_LATER]|[]||0|latest Codex signal is COMMENTED review @ 2026-09-14T00:07:00Z
prior-head-thumbs-do-not-clear-backdated-push|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|$SUP_THUMBS||1|no eligible current-head review or verdict
verdict-older-request-still-clears|[$SUP_REQ123,$SUP_VERDICT]|[$SUP_STALE_4B]|[]||0|AFFIRMATIVE verdict comment @ 2026-09-14T00:02:00Z
codex-thumbs-cannot-answer-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|$SUP_THUMBS_LATER||1|Codex has not cleared current HEAD
codex-verdict-answers-newer-request|[$SUP_REQ123,$SUP_VERDICT,$SUP_REQ124,$SUP_VERDICT_LATER]|[$SUP_STALE_4B]|[]||0|AFFIRMATIVE verdict comment @ 2026-09-14T00:07:00Z
codex-clearance-request-without-timestamp|[$SUP_REQ123,$SUP_REQ_NO_TIME]|[$SUP_CODEX_REVIEW,$SUP_STALE_4B]|[]||1|Codex clearance @ 2026-09-14T00:02:00Z is superseded: Codex request evidence unreadable
CASES
# A Codex clearance whose request re-read fails is superseded (fails closed):
# the first comments read succeeds, every later one fails.
printf '%s\n' "[$SUP_REQ123]" >"$DIR/comments"
printf '%s\n' "[$SUP_CODEX_REVIEW,$SUP_STALE_4B]" >"$DIR/reviews"
: >"$DIR/calls"
rc=0
PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=clearance-reread-fails COMMENTS_FAIL_FROM=2 \
  PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
if [ "$rc" = 0 ] || ! grep -q 'Codex clearance @ 2026-09-14T00:02:00Z is superseded: Codex request evidence could not be re-read' "$DIR/out"; then
  cat "$DIR/out"; echo "FAIL #1598 codex-clearance-reread-fails rc=$rc"; exit 1
fi
PASS=$((PASS + 1))
echo "PASS: #1598 codex-clearance-reread-fails"
# With Codex disabled the substitute is the only gate-(c) path, and a newer
# Codex request supersedes nothing: the checker must clear on the approval
# rather than abort on comments it never read (#1599 round 2).
sed 's/enabled: true/enabled: false/' "$DIR/substitute-policy.yml" >"$DIR/substitute-disabled-policy.yml"
printf '%s\n' '[{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:09:00Z","body":"@codex review"}]' >"$DIR/comments"
printf '%s\n' "$SUB_APPROVAL" >"$DIR/reviews"
: >"$DIR/calls"
rc=0
PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=codex-disabled \
  PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-disabled-policy.yml" \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
if [ "$rc" != 0 ] || ! grep -q 'cleared — Phase 4b substitute' "$DIR/out"; then
  cat "$DIR/out"; echo "FAIL #1598 codex-disabled rc=$rc"; exit 1
fi
PASS=$((PASS + 1))
echo "PASS: #1598 codex-disabled"

# #1752: negative ambiguous anchors remain ordering observations, but must
# never tell a diagnostic caller that the current head was reviewed.
for anchor in missing prefix malformed conflicting exact; do
  case "$anchor" in
    missing) field='' ;;
    prefix) field='Reviewed commit: abcdef0' ;;
    malformed) field='Reviewed commit: abcdef0123456789000000000000000000000000.trailing' ;;
    conflicting) field=$'Reviewed commit: abcdef0123456789000000000000000000000000\nReviewed commit: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
    exact) field='Reviewed commit: abcdef0123456789000000000000000000000000' ;;
  esac
  jq -cn --arg field "$field" '[{user:{login:"chatgpt-codex-connector[bot]"},created_at:"2026-09-14T00:02:00Z",body:("Codex Review: Found issues\n" + $field)}]' > "$DIR/comments"
  printf '[]\n' > "$DIR/reviews"
  : > "$DIR/calls"
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=diagnostic-anchor \
    PR_BODY='' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" --diagnostic-signal-only 99 owner/repo > "$DIR/out" 2>&1 || rc=$?
  if { [ "$anchor" = exact ] && [ "$rc" != 0 ]; } || { [ "$anchor" != exact ] && [ "$rc" = 0 ]; }; then
    cat "$DIR/out"; echo "FAIL diagnostic $anchor rc=$rc"; exit 1
  fi
  PASS=$((PASS + 1)); echo "PASS: diagnostic anchor $anchor"
done

# Resolver infrastructure errors must never look like an account-block waiver.
mv "$DIR/scripts/workflow/resolve-codex-verdict-anchors.py" "$DIR/resolver.saved"
for mode in '' --diagnostic-signal-only --approval-readiness-only; do
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=diagnostic-anchor \
    PR_BODY='' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" ${mode:+"$mode"} 99 owner/repo > "$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != 3 ]; then
    cat "$DIR/out"; echo "FAIL resolver infrastructure $mode rc=$rc"; exit 1
  fi
  PASS=$((PASS + 1)); echo "PASS: resolver infrastructure ${mode:-normal}"
done
mv "$DIR/resolver.saved" "$DIR/scripts/workflow/resolve-codex-verdict-anchors.py"

# Large provider history must travel over stdin, not the OS argument vector.
eval "$(sed -n '/^crc_select_head_review()/,/^}/p' "$ROOT/scripts/codex-review-check.sh")"
large_comments=$(python3 - <<'PYDATA'
import json
print(json.dumps([{'pull_request_review_id':789,'user':{'login':'chatgpt-codex-connector[bot]'},'body':'x'*262144}]))
PYDATA
)
selected=$(crc_select_head_review "$REVIEW" 'chatgpt-codex-connector[bot]' 'abcdef0123456789000000000000000000000000' "$large_comments")
[ "$(printf '%s\n' "$selected" | jq -r '.id')" = 789 ]
PASS=$((PASS + 1))
echo "PASS: large inline history does not exceed the jq argument limit"

# Exercise the complete production requester scan, including its final emitter.
# A large finding must survive both selection and JSON assembly intact.
eval "$(sed -n '/^scan_codex_state() {/,/^}/p' "$ROOT/scripts/codex-review-request.sh")"
python3 - "$DIR" <<'PYDATA'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
bot = {'login': 'chatgpt-codex-connector[bot]'}
root.joinpath('scan-reviews').write_text(json.dumps([{
    'id': 789, 'user': bot, 'commit_id': 'abcdef0123456789000000000000000000000000',
    'submitted_at': '2026-09-14T00:02:00Z', 'state': 'COMMENTED', 'body': 'y' * 262144,
}]))
root.joinpath('scan-inline').write_text(json.dumps([{
    'id': 790, 'pull_request_review_id': 789, 'user': bot,
    'body': '**P2 ' + 'x' * 262144, 'path': 'fixture.sh', 'line': 1,
}]))
PYDATA
fetch_scan_array() {
  case "$2" in
    reviews) cat "$DIR/scan-reviews" ;;
    'inline comments') cat "$DIR/scan-inline" ;;
    'issue comments') printf '[]\n' ;;
    *) return 3 ;;
  esac
}
export BOT_LOGIN='chatgpt-codex-connector[bot]'
export AUTHOR_IDENTITY=nathanjohnpayne
export HEAD_SHA='abcdef0123456789000000000000000000000000'
export REPO=owner/repo PR_NUMBER=99 REQUIRED_TIERS_JSON='["p0","p1"]'
export DISCRETIONARY_TIERS_JSON='["p2","p3","nitpick"]'
export CODEX_FAILURE_MARKERS_OK=false
scan_codex_state >"$DIR/large-scan"
jq -e '.review.id == 789 and (.review.body | length) == 262144
  and (.findings | length) == 1 and (.findings[0].body | length) == 262149
  and .findings[0].blocking == false' "$DIR/large-scan" >/dev/null
PASS=$((PASS + 1))
echo "PASS: requester scans and emits large review and finding bodies over stdin"

# Disabled Codex and approval-readiness paths do not depend on Codex inline reads.
printf '%s\n' "$SUB_APPROVAL" >"$DIR/reviews"
printf '[]\n' >"$DIR/comments"
for mode in disabled readiness; do
  policy="$DIR/substitute-disabled-policy.yml"
  flag=''
  if [ "$mode" = readiness ]; then policy="$DIR/substitute-policy.yml"; flag=--approval-readiness-only; fi
  : >"$DIR/calls"
  timestamp_reads_fail=0
  [ "$mode" != readiness ] || timestamp_reads_fail=1
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=no-inline \
    TIMESTAMP_READS_FAIL="$timestamp_reads_fail" INLINE_COMMENTS_FAIL=1 PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$policy" \
    bash "$DIR/scripts/codex-review-check.sh" ${flag:+"$flag"} 99 owner/repo > "$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != 0 ] || grep -q '^repos/owner/repo/pulls/99/comments$' "$DIR/calls"; then
    cat "$DIR/out"; echo "FAIL $mode depends on irrelevant inline reads rc=$rc"; exit 1
  fi
  if [ "$mode" = readiness ] && grep -Eq '^repos/owner/repo/(commits/|issues/99/timeline$)' "$DIR/calls"; then
    cat "$DIR/calls"; echo 'FAIL readiness depends on timestamp-only reads'; exit 1
  fi
  PASS=$((PASS + 1)); echo "PASS: $mode skips irrelevant API reads"
done

# Exercise the production requester clearance decision on the same provider
# fixtures as gate (b), rather than copying either jq predicate (#1543).
eval "$(sed -n '/^has_cleared_signal()/,/^}/p' "$ROOT/scripts/codex-review-request.sh")"
# A findings-bearing review is not an affirmative approval substitute,
# even after the author replies; discretionary findings still allow it.
printf '[]\n' >"$DIR/comments"
for shape in badge text review-body; do
for tier in P0 P1 P2; do
  finding="![${tier} Badge] finding"
  [ "$shape" = badge ] || finding="**$tier finding**"
  printf '%s\n' "$REVIEW" >"$DIR/reviews"
  inline=$(jq -cn --arg finding "$finding" '[{id:5001,pull_request_review_id:789,user:{login:"chatgpt-codex-connector[bot]"},body:$finding},{id:5002,pull_request_review_id:789,in_reply_to_id:5001,user:{login:"nathanpayne-codex"},body:"Rebutted and resolved."}]')
  if [ "$shape" = review-body ]; then
    printf '%s\n' "$REVIEW" | jq --arg finding "$finding" '.[0].body=$finding' >"$DIR/reviews"
    inline='[]'
  fi
  expected=1; [ "$tier" != P2 ] || expected=0
  : >"$DIR/calls"; rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=blocking-roots \
    INLINE_COMMENTS_JSON="$inline" PR_BODY='Authoring-Agent: codex' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/default-policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ]; then cat "$DIR/out"; echo "FAIL $shape $tier approval substitute rc=$rc"; exit 1; fi
  if [ "$tier" != P2 ] && ! grep -q 'no reviewer identity' "$DIR/out"; then cat "$DIR/out"; exit 1; fi
  cp "$DIR/reviews" "$DIR/scan-reviews"
  printf '%s\n' "$inline" > "$DIR/scan-inline"
  requester_cleared=false
  if has_cleared_signal "$(scan_codex_state)"; then requester_cleared=true; fi
  wanted_clearance=false; [ "$tier" != P2 ] || wanted_clearance=true
  if [ "$requester_cleared" != "$wanted_clearance" ]; then
    echo "FAIL requester/checker disagreement on $shape $tier"; exit 1
  fi
  PASS=$((PASS + 1)); echo "PASS: $shape $tier approval-substitute boundary"
done
done

# A reply-only wrapper on the exact head must leave both paths un-cleared.
printf '%s\n' "$REVIEW" > "$DIR/reviews"
reply_only='[{"id":5003,"pull_request_review_id":789,"in_reply_to_id":5001,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Review Result: Verified commit abcdef0 resolves the reported issue."}]'
printf '%s\n' "$reply_only" > "$DIR/scan-inline"
cp "$DIR/reviews" "$DIR/scan-reviews"
reply_scan=$(scan_codex_state)
if [ "$(printf '%s' "$reply_scan" | jq -r '.review == null')" != true ] \
   || has_cleared_signal "$reply_scan"; then
  echo 'FAIL threaded reply alone suppressed a needed requester trigger'; exit 1
fi
rc=0
PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=blocking-roots \
  INLINE_COMMENTS_JSON="$reply_only" PR_BODY='Authoring-Agent: codex' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/default-policy.yml" \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'no reviewer identity' "$DIR/out"; then
  cat "$DIR/out"; echo "FAIL reply-only checker status rc=$rc"; exit 1
fi
PASS=$((PASS + 1)); echo 'PASS: requester and checker reject threaded-reply-only clearance'

# The real checker must bind a quoted YAML author key, too. Its old line
# grep defaulted to nathanjohnpayne and accepted this base-author request.
sed "s/^author_identity:.*/'author_identity': base-author/" "$DIR/substitute-policy.yml" >"$DIR/quoted-author-policy.yml"
printf '%s\n' '[{"id":8203,"user":{"login":"base-author"},"created_at":"2026-09-14T00:09:00Z","body":"@codex review"}]' >"$DIR/comments"
printf '%s\n' "$SUB_APPROVAL" >"$DIR/reviews"
: >"$DIR/calls"
rc=0
PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=none \
  PR_BODY='Authoring-Agent: claude' PR_AUTHOR=base-author ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/quoted-author-policy.yml" \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'a Codex request by base-author' "$DIR/out"; then
  cat "$DIR/out"; echo "FAIL parsed author checker: rc=$rc"; exit 1
fi
PASS=$((PASS + 1)); echo 'PASS: real checker rejects a later request by the parsed quoted-key author'

# #1618: source the production Phase 4b helpers directly; never dispatch an
# adapter to exercise request-generation authority. Candidate and base policies
# deliberately disagree, as they can on trusted cross-repository orchestration.
(
  # shellcheck source=../scripts/phase-4b/lib.sh
  . "$ROOT/scripts/phase-4b/lib.sh"
  export MERGEPATH_REVIEW_POLICY_PATH="$DIR/candidate.yml"
  export P4B_RESOLVE_BASE_POLICY="$DIR/base-resolver"
  export P4B_TEST_BASE="$DIR/base.yml" P4B_TEST_RESOLVER_LOG="$DIR/resolver-log"
  printf 'author_identity: candidate-author\n' >"$MERGEPATH_REVIEW_POLICY_PATH"
  cat >"$P4B_RESOLVE_BASE_POLICY" <<'RESOLVER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$P4B_TEST_RESOLVER_LOG"
[ "${P4B_TEST_RESOLVER_FAIL:-0}" != 1 ] || exit 2
resolved=$(mktemp)
cp "$P4B_TEST_BASE" "$resolved"
printf '%s\n' "$resolved"
RESOLVER
  chmod +x "$P4B_RESOLVE_BASE_POLICY"
  gh_api_array() { printf '%s\n' "$P4B_TEST_COMMENTS"; }
  P4B_TEST_COMMENTS='[{"id":8201,"user":{"login":"base-author"},"body":"@codex review"},{"id":8202,"user":{"login":"candidate-author"},"body":"@codex review"}]'
  printf 'author_identity: base-author\n' >"$P4B_TEST_BASE"
  captured=$(p4b_live_request_generation owner/repo 99)
  [ "$captured" = '[8201]' ] || { echo "FAIL governing author capture: $captured"; exit 1; }
  P4B_TEST_COMMENTS=$(printf '%s' "$P4B_TEST_COMMENTS" | jq -c '. + [{id:8203,user:{login:"base-author"},body:"@codex review"}]')
  revalidated=$(p4b_live_request_generation owner/repo 99)
  [ "$revalidated" = '[8201,8203]' ] && [ "$revalidated" != "$captured" ] \
    || { echo "FAIL governing author revalidation: $revalidated"; exit 1; }
  [ "$(wc -l <"$P4B_TEST_RESOLVER_LOG" | tr -d ' ')" = 2 ]
  grep -q -- '--repo owner/repo --pr 99 --default-config .*candidate.yml --materialize-default' "$P4B_TEST_RESOLVER_LOG"
  echo 'PASS: governing author capture and revalidation ignore divergent candidate identity'

  # Execute the checker's actual author-assignment block against the same
  # resolved flow-style base policy. Other legacy checker fields still reject
  # full-flow configurations independently; author selection cannot diverge.
  printf '%s\n' '{author_identity: base-author, codex: {enabled: true}}' >"$P4B_TEST_BASE"
  checker_author_block=$(sed -n '/^AUTHOR_POLICY_JSON=/,/^  }$/p' "$ROOT/scripts/codex-review-check.sh")
  [ -n "$checker_author_block" ] || { echo 'FAIL checker parsed-author assignment missing'; exit 1; }
  checker_author=$(export CONFIG="$P4B_TEST_BASE"; eval "$checker_author_block"; printf '%s' "$AUTHOR_IDENTITY")
  [ "$checker_author" = base-author ] \
    || { echo "FAIL flow-style checker author: $checker_author"; exit 1; }
  flow_generation=$(p4b_live_request_generation owner/repo 99)
  [ "$flow_generation" = '[8201,8203]' ] \
    || { echo "FAIL flow-style request generation: $flow_generation"; exit 1; }
  echo 'PASS: valid flow YAML selects the same author in capture and production checker'
  printf '%s\n' '{codex: {enabled: true}}' >"$P4B_TEST_BASE"
  checker_author=$(export CONFIG="$P4B_TEST_BASE"; eval "$checker_author_block"; printf '%s' "$AUTHOR_IDENTITY")
  [ "$checker_author" = nathanjohnpayne ]
  echo 'PASS: checker parsed-author assignment preserves absent-key fallback'
  for invalid in '{author_identity: ""}' '{author_identity: []}' '{author_identity: null}' '{author_identity: [broken'; do
    printf '%s\n' "$invalid" >"$P4B_TEST_BASE"
    rc=0; result=$(export CONFIG="$P4B_TEST_BASE"; eval "$checker_author_block"; printf '%s' "$AUTHOR_IDENTITY") || rc=$?
    [ "$rc" = 3 ] && [ -z "$result" ] || { echo "FAIL checker invalid author: rc=$rc result=$result"; exit 1; }
  done
  echo 'PASS: checker rejects malformed-present author rather than using a default'

  # Preserve the merge checker's absent-key default, but never repair a
  # present invalid identity or unreadable policy with the candidate's login.
  P4B_TEST_COMMENTS='[{"id":8301,"user":{"login":"nathanjohnpayne"},"body":"@codex review"}]'
  printf 'codex:\n  enabled: true\n' >"$P4B_TEST_BASE"
  [ "$(p4b_live_request_generation owner/repo 99)" = '[8301]' ]
  echo 'PASS: absent governing author uses the shared-author compatibility default'
  [ "$(p4b_governing_codex_enabled owner/repo 99)" = true ]
  printf 'codex:\n  enabled: false\n' >"$P4B_TEST_BASE"
  [ "$(p4b_governing_codex_enabled owner/repo 99)" = false ]
  echo 'PASS: shared governing-policy reader preserves Codex enablement'

  for invalid in 'author_identity: ""' 'author_identity: []' 'author_identity: null' 'author_identity: [broken'; do
    printf '%s\n' "$invalid" >"$P4B_TEST_BASE"
    rc=0; result=$(p4b_live_request_generation owner/repo 99) || rc=$?
    [ "$rc" = 2 ] && [ -z "$result" ] || { echo "FAIL invalid governing author: rc=$rc result=$result"; exit 1; }
  done
  echo 'PASS: empty, non-scalar and malformed governing authors fail closed'
  rc=0; result=$(P4B_TEST_RESOLVER_FAIL=1 p4b_live_request_generation owner/repo 99) || rc=$?
  [ "$rc" = 2 ] && [ -z "$result" ] || { echo 'FAIL unreadable governing policy'; exit 1; }
  printf 'author_identity: base-author\n' >"$P4B_TEST_BASE"
  gh_api_array() { return 1; }
  rc=0; result=$(p4b_live_request_generation owner/repo 99) || rc=$?
  [ "$rc" = 2 ] && [ -z "$result" ] || { echo 'FAIL unreadable request history'; exit 1; }
  gh_api_array() { printf '%s\n' '[{"user":{"login":"base-author"},"body":"@codex review"}]'; }
  rc=0; result=$(p4b_live_request_generation owner/repo 99) || rc=$?
  [ "$rc" = 2 ] && [ -z "$result" ] || { echo 'FAIL malformed request identity'; exit 1; }
  echo 'PASS: unreadable policy/history and malformed request evidence fail closed'
)
PASS=$((PASS + 18))

# #1512: exercise the real checker's per-invocation flag contracts. The fake
# GitHub API exposes one red required context; approval and Codex evidence
# then distinguish an ordinary clearance failure from gate-(a)'s CI result.
sed 's/require_ci_green: false/require_ci_green: true/' "$DIR/default-policy.yml" >"$DIR/flag-policy.yml"
FLAG_HEAD=abcdef0123456789000000000000000000000000
FLAG_OLD_HEAD=1111111111111111111111111111111111111111
FLAG_CODEX_COMMENT=$(jq -cn --arg head "$FLAG_HEAD" \
  '{id:990,user:{login:"chatgpt-codex-connector[bot]"},created_at:"2026-09-14T00:05:00Z",body:("Codex Review: Didnt find any major issues.\nReviewed commit: " + $head)}')
flag_reviews() {
  # Three opinionated states for one registered, non-author reviewer.
  jq -cn --arg head "$1" --arg old "$FLAG_OLD_HEAD" '
    [
      {user:{login:"nathanpayne-claude"},state:"APPROVED",commit_id:$head,submitted_at:"2026-09-14T00:02:00Z"},
      {user:{login:"nathanpayne-claude"},state:"APPROVED",commit_id:$old,submitted_at:"2026-09-14T00:03:00Z"}
    ]'
}
FLAG_OLD_LATEST=$(flag_reviews "$FLAG_HEAD")
FLAG_HEAD_LATEST=$(printf '%s' "$FLAG_OLD_LATEST" | jq -c --arg head "$FLAG_HEAD" \
  '. + [{user:{login:"nathanpayne-claude"},state:"APPROVED",commit_id:$head,submitted_at:"2026-09-14T00:04:00Z"}]')
run_flag_checker() { # name reviews comments skip-ci require-head [reviews-fail]
  local name=$1 reviews=$2 comments=$3 skip_ci=$4 require_head=$5 reviews_fail=${6:-0} rc=0
  printf '%s\n' "$reviews" >"$DIR/reviews"
  printf '%s\n' "$comments" >"$DIR/comments"
  printf '[]\n' >"$DIR/ack"
  : >"$DIR/calls"
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=flag-contract \
    PR_BODY='' PR_AUTHOR=contributor ISSUE_REACTIONS='[]' REVIEWS_FAIL="$reviews_fail" BR_RETRY_SLEEP=0 \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/flag-policy.yml" \
    CODEX_REVIEW_CHECK_SKIP_CI="$skip_ci" CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD="$require_head" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/flag-out" 2>&1 || rc=$?
  printf '%s\n' "$rc" >"$DIR/flag-rc"
}

# The CI skip only skips gate (a): without either the reviewer approval or a
# Codex signal, the real checker still returns its normal gate-failure exit 1.
run_flag_checker skip-still-gates '[]' '[]' 1 ''
if [ "$(cat "$DIR/flag-rc")" = 1 ] \
   && grep -q 'gate (a): SKIPPED (codex.require_ci_green=false)' "$DIR/flag-out" \
   && grep -q 'FAIL: no reviewer identity in available_reviewers' "$DIR/flag-out"; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 SKIP_CI skips red CI but reviewer and Codex clearance gates still block'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 SKIP_CI cleared a non-CI gate or did not skip gate (a)'; exit 1
fi

# With a current-head reviewer approval and anchored Codex verdict, the same
# red CI blocks without SKIP_CI and clears with it.
FLAG_HEAD_APPROVAL=$(jq -cn --arg head "$FLAG_HEAD" \
  '[{user:{login:"nathanpayne-claude"},state:"APPROVED",commit_id:$head,submitted_at:"2026-09-14T00:04:00Z"}]')
run_flag_checker red-ci-blocks "$FLAG_HEAD_APPROVAL" "[$FLAG_CODEX_COMMENT]" '' ''
if [ "$(cat "$DIR/flag-rc")" = 1 ] && grep -q 'FAIL: CI not green: 1 non-passing check(s): Build (commit status)=FAILURE' "$DIR/flag-out"; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 red required CI blocks an otherwise-cleared review when SKIP_CI is absent'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 red required CI did not block without SKIP_CI'; exit 1
fi
run_flag_checker skip-red-ci-clears "$FLAG_HEAD_APPROVAL" "[$FLAG_CODEX_COMMENT]" 1 ''
if [ "$(cat "$DIR/flag-rc")" = 0 ] \
   && grep -q 'gate (a): SKIPPED (codex.require_ci_green=false)' "$DIR/flag-out" \
   && grep -q 'gate (b): latest-state APPROVED by nathanpayne-claude' "$DIR/flag-out" \
   && grep -q 'gate (c): cleared' "$DIR/flag-out"; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 SKIP_CI permits the other independently-cleared gates to decide'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 SKIP_CI did not preserve independent clearance gates'; exit 1
fi

# Without the head pin, the latest approval on an old head preserves legacy
# behavior. With it, the latest opinionated state must itself name HEAD: an
# earlier HEAD approval cannot survive a newer approval of an older commit.
run_flag_checker old-approval-default "$FLAG_OLD_LATEST" "[$FLAG_CODEX_COMMENT]" 1 ''
if [ "$(cat "$DIR/flag-rc")" = 0 ]; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 REQUIRE_APPROVAL_ON_HEAD unset preserves the existing any-head approval behavior'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 default approval behavior changed'; exit 1
fi
run_flag_checker latest-old-head-strict "$FLAG_OLD_LATEST" "[$FLAG_CODEX_COMMENT]" 1 1
if [ "$(cat "$DIR/flag-rc")" = 1 ] \
   && grep -q 'FAIL: no reviewer identity in available_reviewers has a latest-state APPROVED review' "$DIR/flag-out"; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 strict head pin rejects a newer old-head opinionated approval despite an earlier HEAD approval'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 strict head pin accepted an old-head latest approval'; exit 1
fi
run_flag_checker latest-head-strict "$FLAG_HEAD_LATEST" "[$FLAG_CODEX_COMMENT]" 1 1
if [ "$(cat "$DIR/flag-rc")" = 0 ] \
   && grep -q 'gate (b): latest-state APPROVED by nathanpayne-claude' "$DIR/flag-out"; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 strict head pin accepts the latest opinionated approval when it names exact HEAD'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 strict head pin rejected the latest exact-head approval'; exit 1
fi

# A real API-read failure remains infrastructure exit 3, distinct from the
# normal not-cleared exit 1 above.
run_flag_checker review-read-infra "$FLAG_HEAD_APPROVAL" "[$FLAG_CODEX_COMMENT]" 1 1 1
if [ "$(cat "$DIR/flag-rc")" = 3 ] && grep -q 'failed to fetch reviews' "$DIR/flag-out"; then
  PASS=$((PASS + 1)); echo 'PASS: #1512 an unreadable reviews API remains infrastructure exit 3'
else
  cat "$DIR/flag-out"; echo 'FAIL: #1512 reviews API failure did not remain infrastructure exit 3'; exit 1
fi

# Review trigger column (specs/codex_request_evidence.md § Codex provider
# surfaces). The rows copy the live Summary shape: a relative-time status cell,
# a Failed cell carrying its retry hint, and the trigger cell last. Only
# `Manual request` is a requested run; `PR opened` and `New commits` are App
# runs nobody asked for; any other text, or a row without the trigger cell, is
# never classified as manual.
summary_trigger_case() { # name trigger-cell status-cell expected-kind|null
  local body comments got
  # shellcheck disable=SC2016 # Literal Markdown commit cell, not shell substitution.
  body=$(printf '<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 {} -->\n\n## Codex Review Summary\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | %s | `abcdef0` |%s\n' "$3" "$2")
  comments=$(jq -nc --arg b "$body" '[{id:9001,user:{login:"chatgpt-codex-connector[bot]"},created_at:"2026-10-29T00:51:58Z",updated_at:"2026-10-29T00:58:07Z",body:$b}]')
  got=$(crqe_select_codex_review_summary "$comments" 'chatgpt-codex-connector[bot]' abcdef0123456789000000000000000000000000) \
    || { echo "FAIL: summary trigger $1: selector failed" >&2; exit 1; }
  if [ "$(printf '%s' "$got" | jq -r 'if . == null then "null" else .trigger_kind end')" = "$4" ]; then
    PASS=$((PASS + 1)); echo "PASS: summary trigger $1 -> $4"
  else
    echo "FAIL: summary trigger $1: $got" >&2; exit 1
  fi
}
SUMMARY_DONE='✅ **Completed** <relative-time datetime="2026-10-29T16:46:28.410836Z">2026-10-29T16:46:28.410836Z</relative-time>'
SUMMARY_RUNNING='🔄 **Running** since <relative-time datetime="2026-10-29T00:58:05.173856Z">2026-10-29T00:58:05.173856Z</relative-time>'
# shellcheck disable=SC2016 # The provider's own backticked retry hint.
SUMMARY_FAILED='⚠️ **Failed** <relative-time datetime="2026-10-28T15:36:42.021653Z">2026-10-28T15:36:42.021653Z</relative-time><br/>We couldn’t complete this review. Comment `@codex review` to try again.'
summary_trigger_case manual-completed ' Manual request |' "$SUMMARY_DONE" manual
summary_trigger_case manual-running ' Manual request |' "$SUMMARY_RUNNING" manual
summary_trigger_case manual-case-and-space '   manual REQUEST   |' "$SUMMARY_DONE" manual
summary_trigger_case pr-opened ' PR opened |' "$SUMMARY_DONE" unsolicited
summary_trigger_case pr-opened-failed ' PR opened |' "$SUMMARY_FAILED" unsolicited
summary_trigger_case new-commits ' New commits |' "$SUMMARY_RUNNING" unsolicited
summary_trigger_case unseen-value ' Ready for review |' "$SUMMARY_DONE" unknown
summary_trigger_case near-miss-manual ' Manual requests |' "$SUMMARY_DONE" unknown
summary_trigger_case manual-prose ' Manual request by @someone |' "$SUMMARY_DONE" unknown
summary_trigger_case missing-column '' "$SUMMARY_DONE" null

# #2881 option (c): a Phase 4b substitute waits while Codex still owes HEAD a
# review, bounded by codex.review_timeout_seconds from a server-derived
# anchor; past the bound it is an explicit timed-out/substitute-used
# fallback. Timestamps are relative to a fixed now so the pure helper is
# deterministic; the end-to-end cases below use the real clock.
P_HEAD=abcdef0123456789000000000000000000000000
P_OTHER=1111111111111111111111111111111111111111
P_BOT='chatgpt-codex-connector[bot]'
P_NOW=1792800000 # 2026-10-23T00:00:00Z
p_at() { jq -nr --argjson s "$1" '$s | todate'; } # epoch -> ISO second
p_req() { jq -nc --argjson id "$1" --arg at "$(p_at "$2")" --arg who "${3:-nathanjohnpayne}" \
  '{id:$id,user:{login:$who,type:"User"},created_at:$at,body:"@codex review"}'; }
p_review() { jq -nc --arg at "$(p_at "$1")" --arg sha "${2:-$P_HEAD}" --arg type "${3:-Bot}" --arg bot "$P_BOT" \
  '{id:700,user:{login:$bot,type:$type},commit_id:$sha,submitted_at:$at,state:"COMMENTED"}'; }
p_comment() { jq -nc --argjson id "$1" --arg at "$(p_at "$2")" --arg up "$(p_at "${4:-$2}")" --arg body "$3" --arg bot "$P_BOT" \
  '{id:$id,user:{login:$bot,type:"Bot"},created_at:$at,updated_at:$up,body:$body}'; }
# A Review Summary: status, run time (epoch, may carry a fraction), JSON commit,
# row commit, comment created/updated.
p_summary() {
  local status=$1 run=$2 jsha=$3 rsha=$4 created=$5 updated=$6 cell
  case "$status" in completed) cell='✅ **Completed**' ;; running) cell='⏳ **Running**' ;; *) cell="**$status**" ;; esac
  jq -nc --arg status "$status" --arg run "$run" --arg jsha "$jsha" --arg rsha "${rsha:0:7}" --arg cell "$cell" \
    --arg created "$(p_at "$created")" --arg updated "$(p_at "$updated")" --arg bot "$P_BOT" '
    {id:900,user:{login:$bot,type:"Bot"},created_at:$created,updated_at:$updated,
     body:("<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 "
       + ({code_review:{commit_sha:$jsha,status:$status},security_review:{status:null}} | tojson)
       + " -->\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | "
       + $cell + " <relative-time datetime=\"" + $run + "\">" + $run + "</relative-time> | `" + $rsha + "` | Manual request |\n")}'
}
P_T0=$((P_NOW - 600))      # the request, ten minutes before now
P_OLD=$((P_NOW - 4000))    # a request past the 1800 s bound
p_check() { # name comments reviews expected-state [expected-reason] [timeout]
  local got
  got=$(crqe_codex_pending_state "$2" "$3" nathanjohnpayne "$P_BOT" "$P_HEAD" "${6:-1800}" "$P_NOW" \
    "$CODEX_USAGE_LIMIT_MARKER_RE" "$CODEX_NOT_CONNECTED_MARKER_RE") \
    || { echo "FAIL #2881 $1: helper exited nonzero"; exit 1; }
  if [ "$(printf '%s' "$got" | jq -r .state)" != "$4" ] \
     || { [ -n "${5:-}" ] && [ "$(printf '%s' "$got" | jq -r .reason)" != "$5" ]; }; then
    echo "FAIL #2881 $1: want $4${5:+/$5}, got $got"; exit 1
  fi
  PASS=$((PASS + 1)); echo "PASS: #2881 pending-state $1 -> $4"
}
# shellcheck source=../scripts/lib/codex-failure-markers.sh
. "$ROOT/scripts/lib/codex-failure-markers.sh"
R0=$(p_req 501 "$P_T0")
p_check no-request '[]' '[]' none no-request
p_check foreign-request-only "[$(p_req 501 "$P_T0" someone-else)]" '[]' none
p_check running-no-response "[$R0]" '[]' pending request-unanswered
p_check no-response-past-bound "[$(p_req 501 "$P_OLD")]" '[]' timed-out request-unanswered
p_check review-after-request "[$R0]" "[$(p_review $((P_T0 + 60)))]" answered
p_check review-same-second "[$R0]" "[$(p_review "$P_T0")]" pending request-unanswered
p_check review-before-request "[$R0]" "[$(p_review $((P_T0 - 60)))]" pending
p_check review-other-head "[$R0]" "[$(p_review $((P_T0 + 60)) "$P_OTHER")]" pending
p_check review-impersonated-user-type "[$R0]" "[$(p_review $((P_T0 + 60)) "$P_HEAD" User)]" pending
p_check new-request-after-answer "[$R0,$(p_req 502 $((P_T0 + 120)))]" "[$(p_review $((P_T0 + 60)))]" pending request-unanswered
p_check new-head-old-answer "[$R0]" "[$(p_review $((P_T0 + 60)) "$P_OTHER")]" pending
p_check affirmative-verdict "[$R0,$(p_comment 601 $((P_T0 + 60)) "Codex Review: Didn't find any major issues.

Reviewed commit: \`$P_HEAD\`")]" '[]' answered
p_check verdict-other-head "[$R0,$(p_comment 601 $((P_T0 + 60)) "Codex Review: Didn't find any major issues.

Reviewed commit: \`$P_OTHER\`")]" '[]' pending
p_check something-went-wrong "[$R0,$(p_comment 601 $((P_T0 + 60)) 'Codex Review: Something went wrong. Try again later by commenting “@codex review”.')]" '[]' answered
p_check usage-limit-refusal "[$R0,$(p_comment 601 $((P_T0 + 60)) 'You have reached your Codex usage limits for code reviews.')]" '[]' answered
p_check summary-completed-after "[$R0,$(p_summary completed "$(p_at $((P_T0 + 90)))" "$P_HEAD" "$P_HEAD" $((P_T0 + 30)) $((P_T0 + 90)))]" '[]' answered
# An unrelated later edit moves updated_at but not the run time Codex wrote.
p_check summary-unrelated-edit "[$R0,$(p_summary completed "$(p_at $((P_T0 - 300)))" "$P_HEAD" "$P_HEAD" $((P_T0 - 400)) $((P_T0 + 200)))]" '[]' pending
p_check summary-fraction-same-second "[$R0,$(p_summary completed "$(p_at "$P_T0" | sed 's/Z$/.900000Z/')" "$P_HEAD" "$P_HEAD" $((P_T0 - 10)) $((P_T0 + 5)))]" '[]' pending
p_check summary-run-after-edit "[$R0,$(p_summary completed "$(p_at $((P_T0 + 500)))" "$P_HEAD" "$P_HEAD" $((P_T0 - 10)) $((P_T0 + 60)))]" '[]' pending
p_check summary-other-head "[$R0,$(p_summary completed "$(p_at $((P_T0 + 90)))" "$P_OTHER" "$P_OTHER" $((P_T0 + 30)) $((P_T0 + 90)))]" '[]' pending
p_check summary-json-row-disagree "[$R0,$(p_summary completed "$(p_at $((P_T0 + 90)))" "$P_HEAD" "$P_OTHER" $((P_T0 + 30)) $((P_T0 + 90)))]" '[]' pending
p_check summary-running-after-answer "[$R0,$(p_summary running "$(p_at $((P_T0 + 120)))" "$P_HEAD" "$P_HEAD" $((P_T0 + 120)) $((P_T0 + 120)))]" "[$(p_review $((P_T0 + 60)))]" pending review-running
p_check running-no-request "[$(p_summary running "$(p_at $((P_T0 + 120)))" "$P_HEAD" "$P_HEAD" $((P_T0 + 120)) $((P_T0 + 120)))]" '[]' pending review-running
p_check running-past-bound "[$(p_summary running "$(p_at "$P_OLD")" "$P_HEAD" "$P_HEAD" "$P_OLD" "$P_OLD")]" '[]' timed-out review-running
p_check review-format-exact "[$R0,$(p_comment 601 $((P_T0 + 60)) "### 💡 Codex Review

https://github.com/o/r/blob/$P_HEAD/a.sh#L1
**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  A finding**")]" '[]' answered
p_check review-format-unanchored "[$R0,$(p_comment 601 $((P_T0 + 60)) '## Review Findings

### [P1] A finding without a permalink')]" '[]' pending
p_check bounded-by-policy-window "[$R0]" '[]' timed-out request-unanswered 300
# Phase 4b round 2 on #2886: a relevant Summary that does not validate is
# never dropped. It holds, bounded from its last edit, and never answers.
P_RUN_BAD=$(p_summary running "$(p_at $((P_T0 + 120)))" "$P_HEAD" "$P_HEAD" $((P_T0 + 120)) $((P_T0 + 120)) | jq -c '.body |= sub("datetime=\"[^\"]*\""; "datetime=\"soon\"")')
p_check summary-running-time-unreadable-no-request "[$P_RUN_BAD]" '[]' pending summary-unreadable
P_DISAGREE=$(p_summary completed "$(p_at $((P_T0 + 90)))" "$P_HEAD" "$P_HEAD" $((P_T0 + 30)) $((P_T0 + 90)) | jq -c '.body |= sub("✅ \\*\\*Completed\\*\\*"; "🔄 **Running** since")')
p_check summary-row-running-json-completed "[$R0,$P_DISAGREE]" '[]' pending request-unanswered
p_check summary-row-json-disagree-no-request "[$P_DISAGREE]" '[]' pending summary-unreadable
p_check summary-failed-agreeing "[$R0,$(p_summary failed "$(p_at $((P_T0 + 90)))" "$P_HEAD" "$P_HEAD" $((P_T0 + 30)) $((P_T0 + 90)) | jq -c '.body |= sub("\\*\\*failed\\*\\*"; "⚠️ **Failed**")')]" '[]' answered
P_BAD_OLD=$(p_summary completed "$(p_at $((P_T0 - 100)))" "$P_HEAD" "$P_HEAD" $((P_T0 - 200)) $((P_T0 - 100)) | jq -c '.body |= sub("codex-review-state:v1 \\{"; "codex-review-state:v1 {broken")')
p_check unreadable-summary-older-than-answer "[$R0,$P_BAD_OLD]" "[$(p_review $((P_T0 + 60)))]" answered
p_check summary-no-json-row-on-head "[$R0,$(printf '%s' "$P_BAD_OLD" | jq -c '.updated_at = "'"$(p_at $((P_T0 + 100)))"'"')]" "[$(p_review $((P_T0 + 60)))]" pending summary-unreadable
if [ "$(crqe_codex_pending_state "[$(printf '%s' "$P_RUN_BAD" | jq -c '.updated_at = "yesterday" | .created_at = "yesterday"')]" '[]' nathanjohnpayne "$P_BOT" "$P_HEAD" 1800 "$P_NOW" | jq -r .state)" = unreadable ]; then
  PASS=$((PASS + 1)); echo 'PASS: #2881 pending-state an unreadable Summary with no readable edit time is unreadable'
else
  echo 'FAIL: #2881 an unreadable Summary without an edit time did not refuse'; exit 1
fi
# The shared classifier: every anchor, disposition and readable time.
c_class() { crqe_codex_comment_signals "$1" "$P_BOT" "$P_HEAD" | jq -r 'map("\(.anchor):\(.affirmative)") | join(",")'; }
if [ "$(c_class "[$(p_comment 701 "$P_T0" "Codex Review: Something.
Reviewed commit: \`$P_OTHER\`
https://github.com/o/r/blob/$P_HEAD/a.sh#L1")]")" = "mixed:false" ] \
  && [ "$(c_class "[$(p_comment 702 "$P_T0" "Codex Review: Didn't find any major issues.
Reviewed commit: \`$P_HEAD\`")]")" = "exact:true" ] \
  && [ "$(c_class "[$(p_comment 703 "$P_T0" "Codex Review: Didn't find any major issues.
Reviewed commit: \`$P_HEAD\`
![P1 Badge](x)")]")" = "exact:false" ] \
  && [ "$(c_class "[$(p_comment 704 "$P_T0" "Codex Review: Didn't find any major issues.
Reviewed commit: \`$P_HEAD\`
https://github.com/o/r/blob/$P_OTHER/a.sh#L1")]")" = "mixed:false" ] \
  && [ "$(c_class "[$(p_comment 705 "$P_T0" "Codex Review: Didn't find any major issues.
Reviewed commit: \`$P_OTHER\`" | jq -c '.created_at = "?" | .updated_at = "?"')]")" = "other:false" ] \
  && ! crqe_codex_comment_signals "[$(p_comment 706 "$P_T0" '![P1 Badge](x) no anchor' | jq -c '.created_at = "?" | .updated_at = "?"')]" "$P_BOT" "$P_HEAD" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo 'PASS: #2881 comment classifier: full anchors, disposition, unreadable negative time refuses'
else
  echo 'FAIL: #2881 comment classifier'; exit 1
fi
# Phase 4b on #2886: only a review run answers. A body-less wrapper whose
# inline comments are all replies does not; a root inline comment, a body, or
# no inline comments at all does (crqe_select_head_review's predicate).
P_WRAP=$(p_review $((P_T0 + 60)) | jq -c '.body = ""')
p_inline() { jq -nc --argjson reply "$1" --arg bot "$P_BOT" '{pull_request_review_id:700,user:{login:$bot,type:"Bot"},in_reply_to_id:(if $reply then 41 else null end)}'; }
p_check reply-wrapper-review "[$R0]" "{\"reviews\":[$P_WRAP],\"inline\":[$(p_inline true)]}" pending request-unanswered
p_check review-with-root-inline "[$R0]" "{\"reviews\":[$P_WRAP],\"inline\":[$(p_inline false)]}" answered
p_check bodyless-review-no-inline "[$R0]" "{\"reviews\":[$P_WRAP],\"inline\":[]}" answered
# Every anchor counts: a HEAD permalink plus a Reviewed commit naming another
# SHA is mixed, so it does not answer; nor does a verdict that pairs a HEAD
# Reviewed commit with another commit's permalink.
p_check review-format-mixed-anchors "[$R0,$(p_comment 601 $((P_T0 + 60)) "https://github.com/o/r/blob/$P_HEAD/a.sh#L1 ![P2 Badge](x)
Reviewed commit: \`$P_OTHER\`")]" '[]' pending
p_check verdict-mixed-anchors "[$R0,$(p_comment 601 $((P_T0 + 60)) "Codex Review: Didn't find any major issues.

Reviewed commit: \`$P_HEAD\`
https://github.com/o/r/blob/$P_OTHER/a.sh#L1")]" '[]' pending
if [ "$(crqe_codex_pending_state "[$(p_req 501 "$P_T0" | jq -c 'del(.created_at)')]" '[]' nathanjohnpayne "$P_BOT" "$P_HEAD" 1800 "$P_NOW" | jq -r .state)" = unreadable ] \
   && [ "$(crqe_codex_pending_state '[]' '[]' nathanjohnpayne "$P_BOT" "$P_HEAD" 18x00 "$P_NOW" | jq -r .state)" = unreadable ] \
   && [ "$(crqe_codex_pending_state '[]' '[]' nathanjohnpayne "$P_BOT" abc 1800 "$P_NOW" | jq -r .state)" = unreadable ]; then
  PASS=$((PASS + 1)); echo 'PASS: #2881 pending-state unreadable request, window or head refuse'
else
  echo 'FAIL: #2881 unreadable pending-state input was accepted'; exit 1
fi
# The anchor is the request's server time: a later evaluation of the same
# evidence reports the same bound, so a rerun cannot extend or reset it.
_e1=$(crqe_codex_pending_state "[$R0]" '[]' nathanjohnpayne "$P_BOT" "$P_HEAD" 1800 "$P_NOW" | jq -r .expires_at)
_e2=$(crqe_codex_pending_state "[$R0]" '[]' nathanjohnpayne "$P_BOT" "$P_HEAD" 1800 $((P_NOW + 900)) | jq -r .expires_at)
[ "$_e1" = "$_e2" ] && [ "$_e1" = "$(p_at $((P_T0 + 1800)))" ] \
  || { echo "FAIL: #2881 the bound moved between evaluations ($_e1 vs $_e2)"; exit 1; }
PASS=$((PASS + 1)); echo 'PASS: #2881 the timeout bound is anchored to the request, not to the evaluation'

# Review-format findings issue comments (#2881). The canonical fixture is the
# late P2 Codex posted on mergepath#1120 five minutes after merge.
F1120=$(jq -c '.comment' "$ROOT/tests/fixtures/codex_late_review_format_1120.json")
F1120_HEAD=$(jq -r '.merge_head' "$ROOT/tests/fixtures/codex_late_review_format_1120.json")
f_anchor() { crqe_review_format_findings "$1" "$P_BOT" "$2" | jq -r 'map(.anchor) | join(",")'; }
while IFS='|' read -r name comments head want; do
  got=$(f_anchor "$comments" "$head") || { echo "FAIL #2881 format $name: selector failed"; exit 1; }
  [ "$got" = "$want" ] || { echo "FAIL #2881 format $name: want '$want', got '$got'"; exit 1; }
  PASS=$((PASS + 1)); echo "PASS: #2881 review-format $name -> ${want:-ignored}"
done <<CASES
1120-merge-head|[$F1120]|$F1120_HEAD|exact
1120-other-head|[$F1120]|$P_HEAD|other
1120-posted-by-user|[$(printf '%s' "$F1120" | jq -c '.user.type = "User"')]|$F1120_HEAD|
1120-other-login|[$(printf '%s' "$F1120" | jq -c '.user.login = "chatgpt-codex-connector"')]|$F1120_HEAD|
task-reply-p1|[$(p_comment 610 "$P_T0" '## Review Findings

### [P1] The lede retains a universal claim')]|$P_HEAD|none
clean-task-reply|[$(p_comment 611 "$P_T0" '## Review Result

No blocking findings.')]|$P_HEAD|
mixed-anchors|[$(p_comment 612 "$P_T0" "https://github.com/o/r/blob/$P_HEAD/a#L1 ![P1 Badge](x) https://github.com/o/r/blob/$P_OTHER/b#L2")]|$P_HEAD|mixed
CASES

# The Review Summary is never a finding, even with a badge in it (its table
# pipes keep it out of the delimited table above).
[ "$(f_anchor "[$(p_summary completed "$(p_at "$P_T0")" "$P_HEAD" "$P_HEAD" "$P_T0" "$P_T0" | jq -c '.body += "\n![P1 Badge](x)"')]" "$P_HEAD")" = "" ] \
  || { echo 'FAIL: #2881 the Review Summary was classified as a findings comment'; exit 1; }
PASS=$((PASS + 1)); echo 'PASS: #2881 review-format summary-is-not-a-finding -> ignored'

# End-to-end through the production checker. A Phase 4b approval that is
# newer than every Codex signal on HEAD, under a substitute-enabled policy.
e_iso() { date -u -r $(( $(date -u +%s) - $1 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
e_run() { # name comments reviews expected-rc pattern
  printf '%s\n' "$2" >"$DIR/comments"
  printf '%s\n' "$3" >"$DIR/reviews"
  printf '[]\n' >"$DIR/ack"
  : >"$DIR/calls"
  rc=0
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ="$1" \
    PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
    MERGEPATH_REVIEW_POLICY_PATH="$DIR/substitute-policy.yml" \
    bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
  if [ "$rc" != "$4" ] || ! grep -qF -- "$5" "$DIR/out"; then
    cat "$DIR/out"; echo "FAIL #2881 e2e $1 rc=$rc (want $4, '$5')"; exit 1
  fi
  PASS=$((PASS + 1)); echo "PASS: #2881 e2e $1"
}
E_REQ_RECENT="{\"id\":123,\"user\":{\"login\":\"nathanjohnpayne\"},\"created_at\":\"$(e_iso 300)\",\"body\":\"@codex review\"}"
E_REQ_OLD="{\"id\":123,\"user\":{\"login\":\"nathanjohnpayne\"},\"created_at\":\"$(e_iso 4000)\",\"body\":\"@codex review\"}"
E_APPROVAL="[{\"user\":{\"login\":\"nathanpayne-codex\"},\"state\":\"APPROVED\",\"commit_id\":\"$P_HEAD\",\"submitted_at\":\"$(e_iso 60)\",\"body\":\"Manual Phase 4b approval\"}]"
E_FINDING_ANSWER="{\"id\":140,\"user\":{\"login\":\"$P_BOT\",\"type\":\"Bot\"},\"created_at\":\"$(e_iso 200)\",\"updated_at\":\"$(e_iso 200)\",\"body\":\"### 💡 Codex Review\\n\\nhttps://github.com/o/r/blob/$P_HEAD/a.sh#L1\\n**<sub><sub>![P2 Badge](x)</sub></sub> A finding**\"}"
E_FINDING_LATE="{\"id\":141,\"user\":{\"login\":\"$P_BOT\",\"type\":\"Bot\"},\"created_at\":\"$(e_iso 30)\",\"updated_at\":\"$(e_iso 30)\",\"body\":\"### 💡 Codex Review\\n\\nhttps://github.com/o/r/blob/$P_HEAD/a.sh#L1\\n**<sub><sub>![P1 Badge](x)</sub></sub> A finding**\"}"
E_RUNNING=$(p_summary running "$(e_iso 20)" "$P_HEAD" "$P_HEAD" 0 0 | jq -c --arg at "$(e_iso 20)" '.created_at = $at | .updated_at = $at')
e_run request-pending "[$E_REQ_RECENT]" "$E_APPROVAL" 1 'Codex still owes abcdef0123456789000000000000000000000000 a review'
e_run request-timed-out "[$E_REQ_OLD]" "$E_APPROVAL" 0 'codex-review-outcome: timed-out/substitute-used'
e_run request-answered-before-approval "[$E_REQ_RECENT,$E_FINDING_ANSWER]" "$E_APPROVAL" 0 'cleared — Phase 4b substitute'
e_run finding-newer-than-approval "[$E_REQ_OLD,$E_FINDING_LATE]" "$E_APPROVAL" 1 'is older than newest Codex bot signal'
e_run run-in-flight-no-request "[$E_RUNNING]" "$E_APPROVAL" 1 'review-running'
if grep -q 'timed-out/substitute-used' "$DIR/out"; then
  echo 'FAIL: #2881 a pending run was reported as a timeout'; exit 1
fi
# Codex P1 on #2886: a recent request answered by a completed run in the first
# comments read, then a newer run Running in the #1598 re-read, must hold. The fresh copy wins;
# with the earlier copy winning the head would read as answered and clear.
E_SUM_DONE=$(p_summary completed "$(e_iso 200)" "$P_HEAD" "$P_HEAD" 0 0 | jq -c --arg c "$(e_iso 300)" --arg u "$(e_iso 200)" '.created_at = $c | .updated_at = $u')
E_SUM_RUN=$(p_summary running "$(e_iso 30)" "$P_HEAD" "$P_HEAD" 0 0 | jq -c --arg c "$(e_iso 300)" --arg u "$(e_iso 30)" '.created_at = $c | .updated_at = $u')
printf '%s\n' "[$E_REQ_RECENT,$E_SUM_RUN]" >"$DIR/comments-reread"
e_run summary-flips-to-running-between-reads "[$E_REQ_RECENT,$E_SUM_DONE]" "$E_APPROVAL" 1 'Codex still owes abcdef0123456789000000000000000000000000 a review'
rm -f "$DIR/comments-reread"
# Phase 4b on #2886: a findings comment that is newer than the approval and
# visible only in the re-read must outrank the approval, not merely answer the
# request: the freshness guard reads the same snapshot as the owed-review check.
printf '%s\n' "[$E_REQ_RECENT,$E_FINDING_LATE]" >"$DIR/comments-reread"
e_run finding-only-in-reread "[$E_REQ_RECENT]" "$E_APPROVAL" 1 'is older than newest Codex bot signal'
rm -f "$DIR/comments-reread"
# The approval must still be its reviewer's latest opinionated state on HEAD
# in the fresh reviews read.
printf '%s\n' "$E_APPROVAL" | jq -c --arg at "$(e_iso 10)" '. + [.[0] + {state: "CHANGES_REQUESTED", submitted_at: $at}]' >"$DIR/reviews-reread"
e_run approval-superseded-in-reread "[$E_REQ_OLD]" "$E_APPROVAL" 1 "no longer nathanpayne-codex's latest opinionated review"
rm -f "$DIR/reviews-reread"
# Phase 4b round 2 on #2886: a negative `Codex Review:` comment whose
# Reviewed commit names another SHA but whose permalink names HEAD (mixed)
# and that only the re-read sees still outranks the older approval.
E_MIXED_LATE="{\"id\":142,\"user\":{\"login\":\"$P_BOT\",\"type\":\"Bot\"},\"created_at\":\"$(e_iso 30)\",\"updated_at\":\"$(e_iso 30)\",\"body\":\"Codex Review: Here are some suggestions.\\n\\nReviewed commit: \\u0060$P_OTHER\\u0060\\nhttps://github.com/o/r/blob/$P_HEAD/a.sh#L1\"}"
printf '%s\n' "[$E_REQ_OLD,$E_MIXED_LATE]" >"$DIR/comments-reread"
e_run mixed-negative-only-in-reread "[$E_REQ_OLD]" "$E_APPROVAL" 1 'is older than newest Codex bot signal'
rm -f "$DIR/comments-reread"
# A clean-looking verdict naming HEAD beside another commit's permalink is
# mixed, so it never clears gate (c) as an affirmative verdict.
E_MIXED_CLEAN="{\"id\":143,\"user\":{\"login\":\"$P_BOT\",\"type\":\"Bot\"},\"created_at\":\"$(e_iso 30)\",\"updated_at\":\"$(e_iso 30)\",\"body\":\"Codex Review: Didn't find any major issues.\\n\\nReviewed commit: \\u0060$P_HEAD\\u0060\\nhttps://github.com/o/r/blob/$P_OTHER/a.sh#L1\"}"
printf '%s\n' "[$E_MIXED_CLEAN]" >"$DIR/comments"; printf '%s\n' "$E_APPROVAL" >"$DIR/reviews"; : >"$DIR/calls"; rc=0
PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=mixed-clean \
  PR_BODY='Authoring-Agent: claude' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/default-policy.yml" \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || rc=$?
if [ "$rc" = 1 ] && grep -qF 'non-affirmative or findings-bearing verdict' "$DIR/out"; then
  PASS=$((PASS + 1)); echo "PASS: #2881 e2e mixed-clean-verdict-never-clears"
else
  cat "$DIR/out"; echo "FAIL #2881 e2e mixed-clean-verdict-never-clears rc=$rc"; exit 1
fi
e_run summary-completed-control "[$E_REQ_RECENT,$E_SUM_DONE]" "$E_APPROVAL" 0 'Codex owes HEAD no review (answered'


echo "test_codex_request_evidence: $PASS blocked/query cases and carry-forward success passed"
