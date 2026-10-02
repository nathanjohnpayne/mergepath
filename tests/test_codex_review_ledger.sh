#!/usr/bin/env bash
# Fixture coverage for the report-only Codex review ledger (#1560, slice 2).
#
# Part 1 drives the pure attribution library (scripts/lib/codex-review-ledger.sh)
# with synthetic timelines, one rule per case. Part 2 runs the real CLI against
# a stubbed gh to pin its read-only, fail-closed contract. Part 3 pins the
# shared verdict expressions to the two scripts that already carry them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

# shellcheck source=../scripts/lib/codex-review-ledger.sh
. "$ROOT/scripts/lib/codex-review-ledger.sh"

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# inputs <requests> <reviews> <verdicts> <reactions> <blocks> [required]
inputs() {
  jq -n --argjson requests "$1" --argjson reviews "$2" --argjson verdicts "$3" \
    --argjson reactions "$4" --argjson blocks "$5" --argjson required "${6:-[\"p1\"]}" \
    --arg head "$HEAD_A" '
    {pr: 1, repo: "o/r", head_sha: $head, author: "nathanjohnpayne",
     bot: "chatgpt-codex-connector[bot]", required_tiers: $required,
     requests: $requests, reviews: $reviews, verdicts: $verdicts,
     reactions: $reactions, blocks: $blocks, summary: null}'
}
req() { # id time [eyes_at|null] [counted]
  jq -nc --argjson id "$1" --arg t "$2" --arg e "${3:-null}" --argjson c "${4:-true}" '
    {id: $id, created_at: $t, counted: $c, source: "issue_comment",
     author: (if $c then "nathanjohnpayne" else "someone-else" end),
     eyes_at: (if $e == "null" then null else $e end)}'
}
review() { # id time head|null root-tiers-json [replies] [body-tiers-json]
  jq -nc --argjson id "$1" --arg t "$2" --arg h "$3" --argjson tiers "$4" \
    --argjson replies "${5:-0}" --argjson bt "${6:-[]}" '
    {id: $id, submitted_at: $t, commit_id: (if $h == "null" then null else $h end), body_tiers: $bt,
     root_findings: [$tiers | to_entries[] | {comment_id: (.key + 1000), tier: .value}],
     reply_comments: $replies, reply_markers: []}'
}
verdict() { jq -nc --argjson id "$1" --arg t "$2" --argjson s "$3" --argjson a "$4" '{comment_id: $id, created_at: $t, reviewed_shas: $s, affirmative: $a}'; }
reaction() { jq -nc --argjson id "$1" --arg t "$2" '{id: $id, created_at: $t}'; }
block() { jq -nc --argjson id "$1" --arg t "$2" --arg r "$3" '{comment_id: $id, created_at: $t, reason: $r}'; }
arr() { jq -sc '.' ; }

check() { # <name> <ledger> <jq-predicate>
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1: predicate $3 failed on $(printf '%s' "$2" | jq -c '{summary, requests: [.requests[] | {id, outcome, candidates, reasons, possible_second_response, reposted_without_response, eyes_before_repost}], responses: [.responses[] | {rid, window, class, anchor, tie, mixed_heads, multiple_in_window, unsolicited, conflicting}]}')"
  fi
}
ledger() { crl_ledger "$(inputs "$@")"; }

T0=2026-09-25T00:00:00Z
T1=2026-09-25T00:05:00Z
T2=2026-09-25T00:10:00Z
T3=2026-09-25T00:15:00Z
T4=2026-09-25T00:20:00Z
T5=2026-09-25T00:25:00Z

# ---- Part 1: attribution rules ---------------------------------------------

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p1","p2"]' | arr)" '[]' '[]' '[]')
check "one request, one blocking review: attributed, blocking" "$L" \
  '.requests[0].outcome == "attributed" and .summary.blocking_responses == 1 and .summary.blocking_responses_solicited == 1'

# #1037 shape: the only blocking review predates every request.
L=$(ledger "$( { req 1 $T1; req 2 $T3; } | arr)" \
  "$( { review 10 $T0 $HEAD_A '["p1"]'; review 11 $T2 $HEAD_B '["p2"]'; review 12 $T4 $HEAD_B '["p3"]'; } | arr)" '[]' '[]' '[]')
check "a review before the first request is unsolicited, not a solicited blocking response" "$L" \
  '.summary.unsolicited_responses == 1 and .summary.blocking_responses == 1 and .summary.blocking_responses_solicited == 0'
check "a later review on the same head as an attributed one is ambiguous: it may be a second answer" "$L" \
  '([.requests[].outcome] == ["attributed","ambiguous"]) and (.requests[0].possible_second_response | length) == 1
   and (.requests[1].reasons | join(" ") | test("second or late answer"))'

L=$(ledger "$( { req 1 $T0; req 2 $T1; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')
check "two requests unresolved when one response lands: both ambiguous, both candidates" "$L" \
  '([.requests[].outcome] == ["ambiguous","ambiguous"]) and (.requests[0].candidates == [1,2])'

# Reviewer counterexample 1: an ambiguous window with debt left over.
L=$(ledger "$( { req 1 $T0; req 2 2026-09-25T00:01:00Z; req 3 $T4; } | arr)" \
  "$( { review 10 $T2 $HEAD_A '["p2"]'; review 11 $T5 $HEAD_B '["p2"]'; } | arr)" '[]' '[]' '[]')
check "after an ambiguous window that may still owe a response, the next response is ambiguous too" "$L" \
  '.requests[2].outcome == "ambiguous" and (.requests[2].candidates | index(1) != null and index(2) != null)
   and (.requests[2].reasons | join(" ") | test("may still owe"))'

L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T4 $HEAD_B '["p1"]'; } | arr)" '[]' '[]' '[]')
check "responses on different heads in successive windows are each attributed" "$L" \
  '([.requests[].outcome] == ["attributed","attributed"])'

L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" '[]' "$(reaction 30 $T4 | arr)" '[]')
check "an anchorless response after the first window is ambiguous with the previous request" "$L" \
  '.requests[1].outcome == "ambiguous" and (.requests[0].possible_second_response | length) == 1'

L=$(ledger "$( { req 1 $T0; req 2 $T1 null false; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')
check "a foreign request is a candidate but not counted" "$L" \
  '.summary.requests == 1 and .summary.foreign_requests == 1 and .requests[0].outcome == "ambiguous"
   and .summary.outcomes.ambiguous == 1 and .summary.foreign_outcomes.ambiguous == 1'

L=$(ledger "$( { req 1 $T0; req 2 2026-09-25T00:01:00Z; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')
check "a re-post without a response and with no eyes now is reported, eyes unknown, never as a retry" "$L" \
  '.requests[0].reposted_without_response == true and .requests[0].eyes_before_repost == "unknown"
   and .requests[0].repost_gap_seconds == 60 and ([.requests[] | has("possible_ack_retry_of")] | any | not)'

L=$(ledger "$( { req 1 $T0 2026-09-25T00:00:05Z; req 2 2026-09-25T00:01:00Z; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')
check "eyes timestamped before the re-post prove the order" "$L" '.requests[0].eyes_before_repost == true'

L=$(ledger "$( { req 1 $T0 2026-09-25T00:02:00Z; req 2 2026-09-25T00:01:00Z; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')
check "eyes timestamped after the re-post are not 'before'" "$L" '.requests[0].eyes_before_repost == false'

L=$(ledger "$(req 1 $T0 | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T2 $HEAD_B '["p1"]'; } | arr)" '[]' '[]' '[]')
check "responses on two heads in one window: mixed, several, ambiguous" "$L" \
  '.summary.responses == 2 and .summary.mixed_head_windows == 1 and .requests[0].outcome == "ambiguous"'

L=$(ledger "$(req 1 $T0 | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T2 $HEAD_A '["p3"]'; } | arr)" '[]' '[]' '[]')
check "two reviews on the same head in one window are two responses, not one" "$L" \
  '.summary.responses == 2 and .summary.multiple_response_windows == 1 and .summary.mixed_head_windows == 0
   and .requests[0].outcome == "ambiguous"'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$(verdict 20 $T1 '["aaaaaaa"]' true | arr)" "$(reaction 30 $T1 | arr)" '[]')
check "an affirmative verdict and a thumbs-up in one window are one clean response" "$L" \
  '.summary.responses == 1 and .responses[0].class == "clean" and .requests[0].outcome == "attributed"'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p1"]' | arr)" '[]' "$(reaction 30 $T2 | arr)" '[]')
check "a blocking review and a thumbs-up in one window keep blocking and are flagged conflicting" "$L" \
  '.responses[0].class == "blocking" and .responses[0].conflicting == true'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" "$(verdict 20 $T2 '["aaaaaaa"]' false | arr)" '[]' '[]')
check "a non-affirmative verdict joins its review and takes the review's class" "$L" \
  '.summary.responses == 1 and .responses[0].anchor == "'"$HEAD_A"'" and .responses[0].class == "discretionary"'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$(verdict 20 $T1 '["aaaaaaa"]' false | arr)" '[]' '[]')
check "a non-affirmative verdict with no review to grade is unknown_tier" "$L" '.responses[0].class == "unknown_tier"'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$(verdict 20 $T1 '[]' true | arr)" '[]' '[]')
check "a verdict without a sha is an anchorless response, not dropped" "$L" \
  '.summary.responses == 1 and .responses[0].anchor == null and .responses[0].class == "clean"'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$(verdict 20 $T1 '["aaaaaaa","bbbbbbb"]' true | arr)" '[]' '[]')
check "a verdict quoting two different heads has no anchor and is flagged" "$L" \
  '.responses[0].anchor == null and .summary.anchor_conflicts == 1'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '[]' 1 | arr)" '[]' '[]' '[]')
check "a review that only wraps thread replies is not a response" "$L" \
  '.summary.responses == 0 and .summary.thread_reply_reviews == 1 and .requests[0].outcome == "no_response_yet"'

L=$(ledger "$(req 1 $T0 | arr)" '[]' '[]' '[]' "$(block 40 $T1 usage_limit | arr)")
check "a provider block is a provider_blocked response" "$L" \
  '.responses[0].class == "provider_blocked" and .responses[0].provider_blocked == ["usage_limit"] and .requests[0].outcome == "attributed"'

L=$(ledger "$( { req 1 $T0; req 2 $T1; } | arr)" '[]' '[]' '[]' '[]')
check "requests with no responses: earlier unanswered, last no_response_yet" "$L" \
  '([.requests[].outcome] == ["unanswered","no_response_yet"])'

# Request 1 is already answered, so only the tie rule can make request 2's
# same-second response ambiguous.
L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T3 $HEAD_B '["p2"]'; } | arr)" '[]' '[]' '[]')
check "a response in the same second as a request is a tie: ambiguous with the previous request" "$L" \
  '.responses[1].tie == true and .requests[0].outcome == "attributed" and .requests[1].outcome == "ambiguous"
   and (.requests[1].candidates | index(1) != null) and (.requests[1].reasons | join(" ") | test("same second"))'

L=$(ledger '[]' "$(review 10 $T1 $HEAD_A '["p1"]' | arr)" '[]' '[]' '[]')
check "with no requests every response is unsolicited" "$L" \
  '.summary.requests == 0 and .summary.unsolicited_responses == 1 and .summary.blocking_responses_solicited == 0'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p0"]' | arr)" '[]' '[]' '[]' '["p1"]')
check "P0 is blocking even when only p1 is required" "$L" '.responses[0].class == "blocking"'
L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]' '["p0","p1","p2","p3","nitpick"]')
check "address-all policy makes a P2 blocking" "$L" '.responses[0].class == "blocking"'
L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["unmarked"]' | arr)" '[]' '[]' '[]')
check "an unmarked root finding is discretionary" "$L" '.responses[0].class == "discretionary"'
L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '[]' 0 '["p1"]' | arr)" '[]' '[]' '[]')
check "a top-level review-body P1 finding is blocking" "$L" '.responses[0].class == "blocking"'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p1"]' | arr)" '[]' '[]' '[]')
check "the ledger states its limits and has no clearance field" "$L" \
  '(.limits | length) == 4 and ([.. | objects | keys[] | select(test("clear"; "i"))] | length) == 0'

# ---- Part 2: CLI contract (stubbed gh, real libs) ---------------------------

make_cli_case() {
  local dir=$1
  mkdir -p "$dir/scripts/lib" "$dir/scripts/workflow" "$dir/.github" "$dir/bin"
  cp "$ROOT/scripts/codex-review-ledger.sh" "$dir/scripts/"
  for lib in gh-api-array.sh codex-request-evidence.sh codex-failure-markers.sh \
             feedback-policy-helpers.sh codex-review-ledger.sh; do
    cp "$ROOT/scripts/lib/$lib" "$dir/scripts/lib/"
  done
  cat >"$dir/scripts/workflow/resolve_base_policy.sh" <<'EOF'
#!/usr/bin/env bash
[ "${LEDGER_TEST_RESOLVER_FAIL:-0}" = 1 ] && exit 3
if [ "${LEDGER_TEST_MATERIALIZE:-0}" = 1 ]; then
  # Like the real resolver for a base-ref policy: a materialized temp copy.
  cp "${LEDGER_TEST_POLICY:?}" "$LEDGER_TEST_DIR/materialized-policy.yml"
  printf '%s\n' "$LEDGER_TEST_DIR/materialized-policy.yml"
  exit 0
fi
printf '%s\n' "${LEDGER_TEST_POLICY:?}"
EOF
  chmod +x "$dir/scripts/workflow/resolve_base_policy.sh"
  cat >"$dir/policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: "chatgpt-codex-connector[bot]"
EOF
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "unexpected gh: $*" >&2; exit 99; }
shift
[ "${1:-}" = --paginate ] && shift
echo "$1" >>"$LEDGER_TEST_DIR/calls"
if [ -n "${LEDGER_TEST_FAIL_ENDPOINT:-}" ] && [ "$1" = "$LEDGER_TEST_FAIL_ENDPOINT" ]; then
  echo '{"message":"Bad Gateway"}'
  echo "gh: HTTP 502 Server Error" >&2
  exit 1
fi
case "$1" in
  repos/o/r/pulls/7) printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' ;;
  repos/o/r/issues/7/comments) cat "$LEDGER_TEST_DIR/issue_comments.json" ;;
  repos/o/r/pulls/7/reviews) cat "$LEDGER_TEST_DIR/reviews.json" ;;
  repos/o/r/pulls/7/comments) cat "$LEDGER_TEST_DIR/review_comments.json" ;;
  repos/o/r/issues/7/reactions) cat "$LEDGER_TEST_DIR/issue_reactions.json" ;;
  repos/o/r/issues/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected endpoint $1" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '[]\n' >"$dir/reviews.json"
  printf '[]\n' >"$dir/review_comments.json"
  printf '[]\n' >"$dir/issue_reactions.json"
}

run_cli() { # <dir> [args...]
  local dir=$1 rc=0
  shift
  ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=stub LEDGER_TEST_DIR="$dir" \
      LEDGER_TEST_POLICY="$dir/policy.yml" MERGEPATH_REVIEW_POLICY_PATH="$dir/policy.yml" \
      ./scripts/codex-review-ledger.sh --repo o/r "$@" 7 >"$dir/out" 2>"$dir/err" ) || rc=$?
  printf '%s\n' "$rc"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-ledger.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

D="$WORK/ok"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 102, user: {login: "nathanpayne-claude"}, body: "@codex review", created_at: "2026-09-25T00:01:00Z"},
        {id: 103, user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:05:00Z",
         body: "Codex Review: Didn'"'"'t find any major issues.\n**Reviewed commit:** `aaaaaaa`"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.summary.requests == 1 and .summary.foreign_requests == 1
     and ([.requests[] | select(.counted) | .id] == [101]) and .responses[0].class == "clean"
     and ([.requests[].outcome] == ["ambiguous","ambiguous"])' "$D/out" >/dev/null; then
  pass "CLI: counts only the governing author's exact requests; another account's request makes the verdict ambiguous"
else
  fail "CLI ok case: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
if ! grep -qvE '^repos/o/r/(pulls/7|issues/7/comments|pulls/7/reviews|pulls/7/comments|issues/7/reactions|issues/comments/[0-9]+/reactions)$' "$D/calls"; then
  pass "CLI: reads only the PR's own records"
else
  fail "CLI read an unexpected endpoint: $(cat "$D/calls")"
fi

D="$WORK/malformed"; make_cli_case "$D"
jq -n '[{id: "x", user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'positive integer id' "$D/err"; then
  pass "CLI: a malformed request id fails closed (exit 3, nothing printed, the cause named)"
else
  fail "CLI malformed id: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/resolver"; make_cli_case "$D"
printf '[]\n' >"$D/issue_comments.json"
RC=$(LEDGER_TEST_RESOLVER_FAIL=1 run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ]; then
  pass "CLI: an unresolvable governing policy fails closed"
else
  fail "CLI resolver failure: rc=$RC out=$(cat "$D/out")"
fi

D="$WORK/summary"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 104, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:01:00Z"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D" --summary)
if [ "$RC" = 0 ] && grep -q '^requests: 2 ' "$D/out" && grep -q 'request 101 .*unanswered' "$D/out"; then
  pass "CLI: --summary prints the counts and lists the unanswered request"
else
  fail "CLI summary: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/emptybot"; make_cli_case "$D"
cat >"$D/policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: ""
EOF
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 103, user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:05:00Z",
         body: "Codex Review: No major issues.\n**Reviewed commit:** `aaaaaaa`"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.bot == "chatgpt-codex-connector[bot]" and .summary.responses == 1' "$D/out" >/dev/null; then
  pass "CLI: an empty codex.bot_login falls back to the default bot, as the gate does"
else
  fail "CLI empty bot_login: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/readfail"; make_cli_case "$D"
printf '[]\n' >"$D/issue_comments.json"
RC=$(LEDGER_TEST_FAIL_ENDPOINT=repos/o/r/pulls/7/reviews run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ]; then
  pass "CLI: a failed read exits 3 and prints nothing"
else
  fail "CLI read failure: rc=$RC out=$(cat "$D/out")"
fi

D="$WORK/cleanup"; make_cli_case "$D"
printf '[]\n' >"$D/issue_comments.json"
RC=$(LEDGER_TEST_MATERIALIZE=1 run_cli "$D")
if [ "$RC" = 0 ] && [ ! -e "$D/materialized-policy.yml" ]; then
  pass "CLI: a materialized governing policy is removed after the run"
else
  fail "CLI cleanup: rc=$RC materialized file still present=$([ -e "$D/materialized-policy.yml" ] && echo yes || echo no)"
fi

D="$WORK/blocks"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 103, user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:02:00Z",
         body: "Codex Review: Here are some findings. You have reached your Codex usage limits for code reviews."},
        {id: 104, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:10:00Z"},
        {id: 105, user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:11:00Z",
         body: "You have reached your Codex usage limits for code reviews."}]' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '([.responses[].class] == ["unknown_tier","provider_blocked"])
     and .responses[1].provider_blocked == ["usage_limit"]' "$D/out" >/dev/null; then
  pass "CLI: a verdict is never a block notice; a plain usage-limit reply is provider_blocked"
else
  fail "CLI blocks: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/replies"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:05:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""},
        {id: 51, user: {login: "nathanpayne-claude"}, submitted_at: "2026-09-25T00:06:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""},
        {id: 52, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:06:05Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""}]' >"$D/reviews.json"
jq -n '[{id: 60, user: {login: "chatgpt-codex-connector[bot]"}, pull_request_review_id: 50, in_reply_to_id: null,
         body: "first line\n![P1 Badge] a finding", created_at: "2026-09-25T00:05:00Z"},
        {id: 61, user: {login: "nathanpayne-claude"}, pull_request_review_id: 51, in_reply_to_id: 60,
         body: "Fixed. The newer uppercase-variant request (@CODEX REVIEW) is covered.", created_at: "2026-09-25T00:06:00Z"},
        {id: 62, user: {login: "chatgpt-codex-connector[bot]"}, pull_request_review_id: 52, in_reply_to_id: 60,
         body: "line one\nTo use Codex here, connect your account\nline three", created_at: "2026-09-25T00:06:05Z"}]' >"$D/review_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.summary.responses == 1 and .responses[0].class == "blocking"
     and .summary.thread_reply_reviews == 1 and .thread_reply_reviews[0].reply_markers == ["not_connected"]
     and .summary.foreign_requests == 1 and ([.requests[] | select(.counted | not) | .source] == ["review_comment"])' "$D/out" >/dev/null; then
  pass "CLI: a request mentioned in a thread reply is foreign; the connector reply is a marked wrapper, not a response"
else
  fail "CLI replies: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/malformed-review"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: "not-an-object", submitted_at: "2026-09-25T00:05:00Z", commit_id: null, body: ""}]' >"$D/reviews.json"
RC=$(run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ]; then
  pass "CLI: a malformed review fails closed instead of producing a partial ledger"
else
  fail "CLI malformed review: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

# ---- Part 3: the shared verdict expressions match their existing copies ----

for expr in 'scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")' \
            'test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")'; do
  for f in scripts/lib/codex-request-evidence.sh scripts/codex-review-request.sh scripts/codex-review-check.sh; do
    if grep -qF -- "$expr" "$ROOT/$f"; then
      pass "verdict expression is byte-identical in $f: $expr"
    else
      fail "verdict expression drifted in $f: $expr"
    fi
  done
done

echo
echo "test_codex_review_ledger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
