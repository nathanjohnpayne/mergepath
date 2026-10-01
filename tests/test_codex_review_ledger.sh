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
     retry_window_seconds: 300, requests: $requests, reviews: $reviews,
     verdicts: $verdicts, reactions: $reactions, blocks: $blocks, summary: null}'
}
req() { jq -nc --argjson id "$1" --arg t "$2" --argjson e "${3:-false}" '{id: $id, created_at: $t, eyes_now: $e}'; }
review() { # id time head root-tiers-json [replies] [body-tiers-json]
  jq -nc --argjson id "$1" --arg t "$2" --arg h "$3" --argjson tiers "$4" \
    --argjson replies "${5:-0}" --argjson bt "${6:-[]}" '
    {id: $id, submitted_at: $t, commit_id: $h, body_tiers: $bt,
     root_findings: [$tiers | to_entries[] | {comment_id: (.key + 1000), tier: .value}],
     reply_comments: $replies, reply_markers: []}'
}
verdict() { jq -nc --argjson id "$1" --arg t "$2" --arg s "$3" --argjson a "$4" '{comment_id: $id, created_at: $t, reviewed_sha: $s, affirmative: $a}'; }
reaction() { jq -nc --argjson id "$1" --arg t "$2" '{id: $id, created_at: $t}'; }
block() { jq -nc --argjson id "$1" --arg t "$2" --arg r "$3" '{comment_id: $id, created_at: $t, reason: $r}'; }
arr() { jq -sc '.' ; }

check() { # <name> <ledger> <jq-predicate>
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1: predicate $3 failed on $(printf '%s' "$2" | jq -c '{summary, requests: [.requests[] | {id, outcome, candidates, possible_ack_retry_of, reposted_while_eyes_present}], responses: [.responses[] | {rid, window, class, anchor, mixed_heads, unsolicited}]}')"
  fi
}

T0=2026-09-25T00:00:00Z
T1=2026-09-25T00:05:00Z
T2=2026-09-25T00:10:00Z
T3=2026-09-25T00:15:00Z
T4=2026-09-25T00:20:00Z

# ---- Part 1: attribution rules ---------------------------------------------

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p1","p2"]' | arr)" '[]' '[]' '[]')")
check "one request, one blocking review: attributed, blocking" "$L" \
  '.requests[0].outcome == "attributed" and .summary.blocking_responses == 1 and .summary.blocking_responses_solicited == 1'

# #1037 shape: the only blocking review predates every request.
L=$(crl_ledger "$(inputs "$( { req 1 $T1; req 2 $T3; } | arr)" \
  "$( { review 10 $T0 $HEAD_A '["p1"]'; review 11 $T2 $HEAD_B '["p2","p2"]'; review 12 $T4 $HEAD_B '["p3"]'; } | arr)" '[]' '[]' '[]')")
check "a review before the first request is unsolicited and not a solicited blocking response" "$L" \
  '.summary.unsolicited_responses == 1 and .summary.blocking_responses == 1 and .summary.blocking_responses_solicited == 0
   and ([.requests[].outcome] == ["attributed","attributed"])'

L=$(crl_ledger "$(inputs "$( { req 1 $T0; req 2 $T1; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')")
check "two requests outstanding when one response lands: both ambiguous, both candidates" "$L" \
  '([.requests[].outcome] == ["ambiguous","ambiguous"]) and (.requests[0].candidates == [1,2])
   and (.requests[0].reason | test("more than one request outstanding"))'

L=$(crl_ledger "$(inputs "$( { req 1 $T0 false; req 2 2026-09-25T00:01:00Z; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')")
check "an unanswered request without eyes, followed within the window, is flagged as a possible retry (not folded)" "$L" \
  '.requests[1].possible_ack_retry_of == 1 and .summary.requests == 2 and .summary.possible_ack_retries == 1'

L=$(crl_ledger "$(inputs "$( { req 1 $T0 false; req 2 $T2; } | arr)" "$(review 10 $T3 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')")
check "a follow-up outside the retry window is not flagged as a retry" "$L" \
  '.requests[1].possible_ack_retry_of == null'

L=$(crl_ledger "$(inputs "$( { req 1 $T0 true; req 2 2026-09-25T00:01:00Z; } | arr)" "$(review 10 $T2 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')")
check "a re-post while the earlier request still shows eyes is flagged as such, not as a retry" "$L" \
  '.requests[0].reposted_while_eyes_present == true and .requests[1].possible_ack_retry_of == null'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T2 $HEAD_B '["p1"]'; } | arr)" '[]' '[]' '[]')")
check "responses on two different heads in one window are separate, mixed-head and ambiguous" "$L" \
  '.summary.responses == 2 and .summary.mixed_head_windows == 1 and .requests[0].outcome == "ambiguous"
   and (.requests[0].reason | test("different head anchors"))'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" '[]' "$(verdict 20 $T1 aaaaaaa true | arr)" "$(reaction 30 $T1 | arr)" '[]')")
check "an affirmative verdict and a thumbs-up in one window are one clean response" "$L" \
  '.summary.responses == 1 and .responses[0].class == "clean" and .requests[0].outcome == "attributed"'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p1"]' | arr)" '[]' "$(reaction 30 $T2 | arr)" '[]')")
check "a blocking review and a thumbs-up in one window keep the blocking class and are flagged conflicting" "$L" \
  '.responses[0].class == "blocking" and .responses[0].conflicting == true'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" "$(verdict 20 $T1 aaaaaaa false | arr)" '[]' '[]')")
check "a verdict whose short sha prefixes a review's head joins that review's response" "$L" \
  '.summary.responses == 1 and .responses[0].anchor == "'"$HEAD_A"'" and .responses[0].class == "unknown_tier"'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '[]' 1 | arr)" '[]' '[]' '[]')")
check "a review that only wraps thread replies is not a response and is reported separately" "$L" \
  '.summary.responses == 0 and .summary.thread_reply_reviews == 1 and .requests[0].outcome == "no_response_yet"'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" '[]' '[]' '[]' "$(block 40 $T1 usage_limit | arr)")")
check "a provider block is a provider_blocked response" "$L" \
  '.responses[0].class == "provider_blocked" and .responses[0].provider_blocked == ["usage_limit"] and .requests[0].outcome == "attributed"'

L=$(crl_ledger "$(inputs "$( { req 1 $T0; req 2 $T1; } | arr)" '[]' '[]' '[]' '[]')")
check "requests with no responses: earlier unanswered, last no_response_yet" "$L" \
  '([.requests[].outcome] == ["unanswered","no_response_yet"])'

L=$(crl_ledger "$(inputs "$( { req 1 $T0; req 2 $T1; } | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]')")
check "a signal in the same second as a later request belongs to that later request's window" "$L" \
  '.responses[0].window == 2'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p0"]' | arr)" '[]' '[]' '[]' '["p1"]')")
check "P0 is blocking even when only p1 is required" "$L" '.responses[0].class == "blocking"'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" '[]' '[]' '[]' '["p0","p1","p2","p3","nitpick"]')")
check "address-all policy makes a P2 blocking" "$L" '.responses[0].class == "blocking"'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["unmarked"]' | arr)" '[]' '[]' '[]')")
check "an unmarked root finding is discretionary, never blocking" "$L" '.responses[0].class == "discretionary"'

L=$(crl_ledger "$(inputs "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '[]' 0 '["p1"]' | arr)" '[]' '[]' '[]')")
check "a top-level review-body P1 finding is blocking" "$L" '.responses[0].class == "blocking"'

L=$(crl_ledger "$(inputs "$( { req 1 $T0; req 2 $T2; } | arr)" "$( { review 10 $T1 $HEAD_A '["p1"]'; review 11 $T3 $HEAD_B '["p2"]'; } | arr)" '[]' '[]' '[]')")
check "the ledger reports response classes only; it emits no clearance field" "$L" \
  '([paths | map(tostring) | join(".") | select(test("clear"; "i"))] | length) == 0'

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
case "$1" in
  repos/o/r/pulls/7) printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' ;;
  repos/o/r/issues/7/comments) cat "$LEDGER_TEST_DIR/issue_comments.json" ;;
  repos/o/r/pulls/7/reviews) cat "$LEDGER_TEST_DIR/reviews.json" ;;
  repos/o/r/pulls/7/comments) cat "$LEDGER_TEST_DIR/review_comments.json" ;;
  repos/o/r/issues/7/reactions) printf '[]\n' ;;
  repos/o/r/issues/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected endpoint $1" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '[]\n' >"$dir/reviews.json"
  printf '[]\n' >"$dir/review_comments.json"
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
if [ "$RC" = 0 ] && jq -e '.summary.requests == 1 and .requests[0].id == 101 and .responses[0].class == "clean"
     and .requests[0].outcome == "attributed"' "$D/out" >/dev/null; then
  pass "CLI: counts only the governing author's exact requests and attributes the clean verdict"
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
