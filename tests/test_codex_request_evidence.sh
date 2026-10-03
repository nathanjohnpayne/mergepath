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
  repos/owner/repo/pulls/99) jq -cn --arg body "$PR_BODY" --arg author "$PR_AUTHOR" '{head:{sha:"abcdef0123456789"},user:{login:$author},body:$body,labels:[]}' ;;
  repos/owner/repo/commits/*) echo '2026-09-14T00:00:00Z' ;;
  repos/owner/repo/issues/99/comments)
    if [ -n "${COMMENTS_FAIL_FROM:-}" ] \
       && [ "$(grep -c '^repos/owner/repo/issues/99/comments$' "$CALLS")" -ge "$COMMENTS_FAIL_FROM" ]; then
      exit 1
    fi
    cat "$FIXTURES/comments" ;;
  repos/owner/repo/pulls/99/reviews) cat "$FIXTURES/reviews" ;;
  repos/owner/repo/issues/comments/123/reactions) [ "$ACK_READ" != error ] || exit 1; cat "$FIXTURES/ack" ;;
  repos/owner/repo/issues/comments/124/reactions) echo '[]' ;;
  repos/owner/repo/issues/99/reactions) printf '%s\n' "$ISSUE_REACTIONS" ;;
  repos/owner/repo/issues/99/timeline|repos/owner/repo/pulls/99/comments) echo '[]' ;;
  graphql) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}' ;;
  *) echo "unexpected $*" >&2; exit 99 ;;
esac
GH
chmod +x "$DIR/bin/gh"
TRIGGER='{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@codex review"}'
LATER_MENTION='{"id":124,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:03:00Z","body":"Status: @codex review was already requested."}'
EYES='[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes","created_at":"2026-09-14T00:02:00Z"}]'
# shellcheck disable=SC2016 # Literal Markdown commit cell, not shell substitution.
RUNNING='{"id":456,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:02:00Z","body":"<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | **Running** | `abcdef0` | Manual |"}'
REVIEW='[{"id":789,"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:02:00Z","state":"COMMENTED"}]'
PASS=0
while IFS='|' read -r name comments ack reviews mode opted expected pattern reads; do
  case "$comments" in
    trigger) comments="[$TRIGGER]" ;;
    wrong-id) comments="[${TRIGGER/123/124}]" ;;
    mention-only) comments="[$LATER_MENTION]" ;;
    trigger-then-mention) comments="[$TRIGGER,$LATER_MENTION]" ;;
    mention-running) comments="[$LATER_MENTION,$RUNNING]" ;;
    future) comments="[${TRIGGER/2026-09-14T00:01:00Z/2077-09-14T00:01:00Z}]" ;;
    stale) comments="[${TRIGGER/2026-09-14T00:01:00Z/2026-09-13T00:01:00Z}]" ;;
    foreign) comments="[${TRIGGER/nathanjohnpayne/nathanpayne-claude}]" ;;
    running) comments="[$RUNNING]" ;;
    completed) comments="[${RUNNING/Running/Completed}]" ;;
    *) comments='[]' ;;
  esac
  case "$ack" in eyes) ack="$EYES" ;; foreign) ack="${EYES/chatgpt-codex-connector\[bot\]/someone}" ;; *) ack='[]' ;; esac
  case "$reviews" in
    review) reviews="$REVIEW" ;;
    approved) reviews='[{"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:02:00Z"}]' ;;
  esac
  printf '%s\n' "$comments" >"$DIR/comments"
  printf '%s\n' "$ack" >"$DIR/ack"
  printf '%s\n' "$reviews" >"$DIR/reviews"
  : >"$DIR/calls"
  cp "$DIR/default-policy.yml" "$DIR/policy.yml"
  [ "$name" != unknown-budget ] || sed -i.bak 's/review_timeout_seconds:.*/review_timeout_seconds: unavailable/' "$DIR/policy.yml"
  [ "$name" != default-budgets ] || sed -i.bak '/review_timeout_seconds:/d; /ack_wait_seconds:/d' "$DIR/policy.yml"
  pr_body='Authoring-Agent: codex'; pr_author=nathanjohnpayne; issue_reactions='[]'
  if [ "$name" = thumbs-unapproved ]; then
    pr_body=''; pr_author=contributor; issue_reactions="${EYES/eyes/+1}"
  fi
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
  if [ "$name" = requested ]; then
    grep -Eq 'age=[0-9]+s; configured ack_wait_seconds=30; review_timeout_seconds=840' "$DIR/out"
    grep -q 'not immutable SHA attribution' "$DIR/out"
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
readiness|trigger|eyes|[]|--approval-readiness-only|1|1|no reviewer identity|0
diagnostic|trigger|eyes|[]|--diagnostic-signal-only|1|1|Codex has not produced|0
CASES
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
[ "$(grep -c '/issues/comments/' "$DIR/calls" || true)" = 0 ]

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
! crqe_trigger_generation '[{"id":"bad","user":{"login":"nathanjohnpayne"},"body":"@codex review"}]' nathanjohnpayne >/dev/null 2>&1
echo "PASS: shared exact-request generation selector"

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
SUB_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:05:00Z"}]'
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
RACE_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:05:00Z","body":"Automated Phase 4b review\n<!-- mergepath-p4b-request-generation: [123] -->"}]'
COVERED_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:05:00Z","body":"Automated Phase 4b review\n<!-- mergepath-p4b-request-generation: [123,124] -->"}]'
# Two markers (e.g. a writer record plus a copy in reviewer-controlled text)
# are ambiguous: fail closed rather than trust either (Codex on #1599 round 4).
DUP_RECORD_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:05:00Z","body":"<!-- mergepath-p4b-request-generation: [123,124] -->\n<!-- mergepath-p4b-request-generation: [123,124] -->"}]'
INVALID_RECORD_APPROVAL='[{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:05:00Z","body":"Automated Phase 4b review\n<!-- mergepath-p4b-request-generation: [123,\"x\"] -->"}]'
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
# clearance form is covered: a clean COMMENTED review, a thumbs-up reaction,
# an affirmative verdict comment and a carried-forward verdict. Codex
# answering the newer request (a later review) clears again.
SUP_REQ123='{"id":123,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:01:00Z","body":"@codex review"}'
SUP_REQ124='{"id":124,"user":{"login":"nathanjohnpayne"},"created_at":"2026-09-14T00:04:00Z","body":"@codex review"}'
SUP_VERDICT='{"id":130,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:02:00Z","body":"Codex Review: Didn'"'"'t find any major issues.\n\nReviewed commit: `abcdef0`"}'
SUP_STALE_4B='{"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:05:00Z","body":"<!-- mergepath-p4b-request-generation: [123] -->"}'
SUP_CODEX_REVIEW='{"id":789,"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:02:00Z","state":"COMMENTED","body":""}'
SUP_CODEX_REVIEW_LATER='{"id":790,"user":{"login":"chatgpt-codex-connector[bot]"},"commit_id":"abcdef0123456789","submitted_at":"2026-09-14T00:07:00Z","state":"COMMENTED","body":""}'
SUP_THUMBS='[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-09-14T00:02:00Z"}]'
SUP_THUMBS_LATER='[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-09-14T00:02:00Z"},{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-09-14T00:07:00Z"}]'
SUP_VERDICT_LATER='{"id":131,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-09-14T00:07:00Z","body":"Codex Review: Didn'"'"'t find any major issues.\n\nReviewed commit: `abcdef0`"}'
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
thumbs-then-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|$SUP_THUMBS||1|Codex clearance @ 2026-09-14T00:02:00Z is superseded
verdict-then-newer-request|[$SUP_REQ123,$SUP_VERDICT,$SUP_REQ124]|[$SUP_STALE_4B]|[]||1|Codex clearance @ 2026-09-14T00:02:00Z is superseded
carry-then-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|[]|{"carried":true,"source_time":"2026-09-14T00:02:00Z","source_commit":"oldhead","fingerprint":"same"}|1|Codex clearance @ 2026-09-14T00:02:00Z is superseded
review-older-request-still-clears|[$SUP_REQ123]|[$SUP_CODEX_REVIEW,$SUP_STALE_4B]|[]||0|latest Codex signal is COMMENTED review @ 2026-09-14T00:02:00Z
codex-answers-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_CODEX_REVIEW,$SUP_STALE_4B,$SUP_CODEX_REVIEW_LATER]|[]||0|latest Codex signal is COMMENTED review @ 2026-09-14T00:07:00Z
thumbs-older-request-still-clears|[$SUP_REQ123]|[$SUP_STALE_4B]|$SUP_THUMBS||0|latest Codex signal is 👍 reaction @ 2026-09-14T00:02:00Z
verdict-older-request-still-clears|[$SUP_REQ123,$SUP_VERDICT]|[$SUP_STALE_4B]|[]||0|AFFIRMATIVE verdict comment @ 2026-09-14T00:02:00Z
codex-thumbs-answers-newer-request|[$SUP_REQ123,$SUP_REQ124]|[$SUP_STALE_4B]|$SUP_THUMBS_LATER||0|latest Codex signal is 👍 reaction @ 2026-09-14T00:07:00Z
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

echo "test_codex_request_evidence: $PASS blocked/query cases and carry-forward success passed"
