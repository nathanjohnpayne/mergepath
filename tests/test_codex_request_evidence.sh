#!/usr/bin/env bash
# #1276: real checker, fake provider. Diagnostics must never decide clearance.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
  repos/owner/repo/issues/99/comments) cat "$FIXTURES/comments" ;;
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
    completed-*) ! grep -q 'monitor provider progress' "$DIR/out" ;;
    thumbs-unapproved)
      ! grep -Eq 'no matching provider activity|request review through' "$DIR/out"
      ! grep -q '/issues/99/reactions' "$DIR/calls" ;;
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
default-budgets|trigger|none|[]||1|1|configured ack_wait_seconds=30; review_timeout_seconds=840|1
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
CARRY_FIXTURE='{"carried":true,"source_time":"2026-09-14T00:00:00Z","source_commit":"oldhead","fingerprint":"same"}' \
  PATH="$DIR/bin:$PATH" GH_TOKEN=stub FIXTURES="$DIR" CALLS="$DIR/calls" ACK_READ=error \
  PR_BODY='Authoring-Agent: codex' PR_AUTHOR=nathanjohnpayne ISSUE_REACTIONS='[]' \
  MERGEPATH_REVIEW_POLICY_PATH="$DIR/policy.yml" CODEX_REVIEW_CHECK_REPORT_REQUEST_EVIDENCE=1 \
  bash "$DIR/scripts/codex-review-check.sh" 99 owner/repo >"$DIR/out" 2>&1 || { cat "$DIR/out"; exit 1; }
if grep -q 'request evidence' "$DIR/out"; then echo 'FAIL: diagnostic on success'; exit 1; fi
[ "$(grep -c '/issues/comments/' "$DIR/calls" || true)" = 0 ]
echo "test_codex_request_evidence: $PASS blocked/query cases and carry-forward success passed"
