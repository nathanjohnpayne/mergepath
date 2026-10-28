#!/usr/bin/env bash
# Fixture coverage for the Codex review ledger (#1560): built report-only in
# slice 2; since slice 3 the requester reads its blocking-review count.
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
# shellcheck source=../scripts/lib/codex-request-evidence.sh
. "$ROOT/scripts/lib/codex-request-evidence.sh"

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_C=cccccccccccccccccccccccccccccccccccccccc

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

# ---- Input timestamps (#1578) ----------------------------------------------
# Every named field is populated so each mutation exercises exactly one bad
# instant in an otherwise valid input to the production pure library.
TIMED_INPUT=$(inputs "$(req 1 "$T0" "$T1" | arr)" "$(review 10 "$T2" "$HEAD_A" '["p1"]' | arr)" \
  "$(verdict 20 "$T3" '["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' true | arr)" \
  "$(reaction 30 "$T4" | arr)" "$(block 40 "$T5" usage_limit | arr)" \
  | jq -c --arg t "$T5" '.rebuttals = [{finding: 100, path: null, at: $t, sources: []}]
                         | .summary = {status: "completed", observed_at: $t}')
timestamp_refused() { # name input: no successful or partial ledger is usable
  local output rc=0
  output=$(crl_ledger "$2" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$output" ]; then
    pass "$1"
  else
    fail "$1: rc=$rc output=$output"
  fi
}
for _field in requests.0.created_at requests.0.eyes_at reviews.0.submitted_at \
  verdicts.0.created_at blocks.0.created_at reactions.0.created_at rebuttals.0.at summary.observed_at; do
  _path=$(jq -nc --arg f "$_field" '$f | split(".") | map(tonumber? // .)')
  timestamp_refused "timestamp: $_field rejects a malformed instant" \
    "$(jq -c --argjson p "$_path" 'setpath($p; "!")' <<<"$TIMED_INPUT")"
  # The parser removes the first fraction anywhere; syntax must establish
  # that it belongs to seconds before that conversion (#2528 review).
  for _instant in 2026-09-25T00:00:01Z.123 2026.123-09-25T00:00:01Z; do
    timestamp_refused "timestamp: $_field rejects misplaced fraction $_instant" \
      "$(jq -c --argjson p "$_path" --arg t "$_instant" 'setpath($p; $t)' <<<"$TIMED_INPUT")"
  done
  L=$(crl_ledger "$(jq -c --argjson p "$_path" 'setpath($p; "2026-09-25T00:00:01.123Z")' <<<"$TIMED_INPUT")")
  check "timestamp: $_field accepts a seconds fraction" "$L" '.summary.requests == 1'
  # eyes_at alone is nullable; every other present record requires its instant.
  for _bad in missing null number boolean array object; do
    if [ "$_field" = requests.0.eyes_at ] && { [ "$_bad" = missing ] || [ "$_bad" = null ]; }; then continue; fi
    timestamp_refused "timestamp: $_field rejects $_bad" \
      "$(jq -c --argjson p "$_path" --arg bad "$_bad" '
        if $bad == "missing" then delpaths([$p])
        else setpath($p; ({null: null, number: 17, boolean: true, array: [], object: {}}[$bad])) end' <<<"$TIMED_INPUT")"
  done
done
L=$(crl_ledger "$(jq -c 'walk(if type == "string" and test("Z$") then sub("Z$"; ".123Z") else . end)' <<<"$TIMED_INPUT")")
check "timestamp: fractional UTC instants remain valid in every field" "$L" \
  '.summary.requests == 1 and .summary.blocking_responses_solicited == 1 and .requests[0].eyes_at == "2026-09-25T00:05:00.123Z"'
L=$(crl_ledger "$(jq -c '.requests[0].eyes_at = null' <<<"$TIMED_INPUT")")
check "timestamp: null eyes remain valid" "$L" '.summary.eyes_now == 0 and .summary.blocking_responses_solicited == 1'
L=$(crl_ledger "$(jq -c 'del(.reactions, .rebuttals, .summary) | .metadata = {created_at: "!"}' <<<"$TIMED_INPUT")")
check "timestamp: absent optional evidence and unrelated metadata remain valid" "$L" \
  '.rebuttals == [] and .current_summary == null and .summary.blocking_responses_solicited == 1'
L=$(crl_ledger "$(jq -c 'del(.requests[0].eyes_at) | .reactions = null | .rebuttals = null | .summary = null' <<<"$TIMED_INPUT")")
check "timestamp: absent eyes and null optional evidence retain their defaults" "$L" \
  '.requests[0].eyes_at == null and .rebuttals == [] and .current_summary == null and .summary.blocking_responses_solicited == 1'
# Budget impact: the valid blocking review counts as one; changing only its
# instant must refuse the ledger, never turn it into window 0 / count zero.
_budget_input=$(inputs "$(req 1 "$T0" | arr)" "$(review 10 "$T1" "$HEAD_A" '["p1"]' | arr)" '[]' '[]' '[]')
L=$(crl_ledger "$_budget_input")
if [ "$(crl_blocking_count "$L" "$HEAD_A" nathanjohnpayne)" = 1 ]; then
  pass "timestamp: valid solicited review consumes the blocking budget"
else
  fail "timestamp: valid solicited review did not consume the blocking budget"
fi
timestamp_refused "timestamp: malformed blocking review cannot escape the budget as unsolicited" \
  "$(jq -c '.reviews[0].submitted_at = "!"' <<<"$_budget_input")"

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

# #1572: two responses with two requests outstanding may both answer the
# first, so the window pays nothing and both stay candidates afterwards.
L=$(ledger "$( { req 1 $T0; req 2 2026-09-25T00:01:00Z; req 3 $T4; } | arr)" \
  "$( { review 10 $T2 $HEAD_A '["p2"]'; review 11 $T3 $HEAD_B '["p2"]'; review 12 $T5 $HEAD_C '["p2"]'; } | arr)" '[]' '[]' '[]')
check "#1572: an ambiguous window with two candidates settles nothing, even with two responses" "$L" \
  '.requests[2].outcome == "ambiguous" and (.requests[2].candidates | index(1) != null and index(2) != null)'

# #1573: an ambiguous window still records the heads its request may have
# been answered on, so a later same-head response may be a second answer.
L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" \
  "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T2 $HEAD_A '["p3"]'; review 12 $T4 $HEAD_A '["p2"]'; } | arr)" '[]' '[]' '[]')
check "#1573: anchors from an ambiguous window make a later same-head response a possible second answer" "$L" \
  '.requests[1].outcome == "ambiguous" and (.requests[1].candidates | index(1) != null)
   and (.requests[0].possible_second_response | length) == 1'

# A window whose only candidate is its own request settles it, even with two
# responses, so a later response on a new head is attributed.
L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" \
  "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T2 $HEAD_B '["p3"]'; review 12 $T4 $HEAD_C '["p2"]'; } | arr)" '[]' '[]' '[]')
check "a several-response window with one candidate settles it; a later new-head response is attributed" "$L" \
  '.requests[0].outcome == "ambiguous" and .requests[1].outcome == "attributed" and .summary.open_debt == 0'

L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T4 $HEAD_B '["p1"]'; } | arr)" '[]' '[]' '[]')
check "responses on different heads in successive windows are each attributed" "$L" \
  '([.requests[].outcome] == ["attributed","attributed"])'

L=$(ledger "$( { req 1 $T0; req 2 $T3; } | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" '[]' '[]' "$(block 30 $T4 usage_limit | arr)")
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
check "an affirmative verdict is the clean response; a thumbs-up adds no evidence" "$L" \
  '.summary.responses == 1 and .responses[0].class == "clean" and .requests[0].outcome == "attributed"'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p1"]' | arr)" '[]' "$(reaction 30 $T2 | arr)" '[]')
check "a blocking review and a thumbs-up keep blocking without reaction authority" "$L" \
  '.responses[0].class == "blocking" and .responses[0].conflicting == false'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" "$(verdict 20 $T2 '["aaaaaaa"]' false | arr)" '[]' '[]')
check "a non-affirmative verdict joins its review and takes the review's class" "$L" \
  '.summary.responses == 1 and .responses[0].anchor == "'"$HEAD_A"'" and .responses[0].class == "discretionary"'

L=$(ledger "$(req 1 $T0 | arr)" "$(review 10 $T1 $HEAD_A '["p2"]' | arr)" "$( { verdict 20 $T2 '["aaaaaaa"]' true; verdict 21 $T3 '["aaaaaaa"]' false; } | arr)" '[]' '[]')
check "contradictory verdicts beside a review keep the review class and are flagged conflicting" "$L" \
  '.responses[0].class == "discretionary" and .responses[0].conflicting == true'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$(verdict 20 $T1 '["aaaaaaa"]' false | arr)" '[]' '[]')
check "a non-affirmative verdict with no review to grade is unknown_tier" "$L" '.responses[0].class == "unknown_tier"'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$( { verdict 20 $T1 '["aaaaaaa"]' true; verdict 21 $T2 '["'"$HEAD_A"'"]' true; } | arr)" '[]' '[]')
check "standalone verdicts on one head at different sha lengths are not a mixed-head window" "$L" \
  '.summary.responses == 2 and .summary.mixed_head_windows == 0 and .summary.multiple_response_windows == 1'

L=$(ledger "$(req 1 $T0 | arr)" '[]' "$( { verdict 20 $T1 '["abcdef1"]' true; verdict 21 $T2 '["abcdef1111111111111111111111111111111111"]' true; verdict 22 $T3 '["abcdef1222222222222222222222222222222222"]' true; } | arr)" '[]' '[]')
check "a short sha matching two different full shas does not merge them: the window is mixed-head" "$L" \
  '.summary.mixed_head_windows == 1'

L=$(ledger "$(req 1 $T0 | arr)" "$( { review 10 $T1 null '["p2"]'; review 11 $T2 null '["p3"]'; } | arr)" '[]' '[]' '[]')
check "anchorless reviews are one response each, never duplicated into a free-signal response" "$L" \
  '.summary.responses == 2 and ([.responses[].signals | length] == [1,1])'

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
   and (.requests[1].candidates | index(1) != null) and (.requests[1].reasons | join(" ") | test("same second"))
   and .requests[0].possible_second_response == ["w2.0"]'

# Requests 2 and 3 share a second, and a response lands in it: the response
# may precede both, so request 1 (the last one strictly before) is a candidate.
L=$(ledger "$( { req 1 $T0; req 2 $T3; req 3 $T3; } | arr)" "$( { review 10 $T1 $HEAD_A '["p2"]'; review 11 $T3 $HEAD_B '["p2"]'; } | arr)" '[]' '[]' '[]')
check "a tie in a second shared by several requests includes the request before that second" "$L" \
  '.requests[0].outcome == "attributed" and (.requests[0].possible_second_response | length) == 1
   and ([.requests[1:][] | .candidates | (index(1) != null and index(2) != null and index(3) != null)] | all)'

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
  '(.limits | length) == 5 and any(.limits[]; test("edited or deleted request")) and ([.. | objects | keys[] | select(test("clear"; "i"))] | length) == 0'

# ---- Part 1b: blocking-review count and human stops (#1560 slice 3) ---------

# preview <id> <time> <path-tier-pairs-json> [body-tiers-json]: a review whose
# root findings carry paths, e.g. '[["x.sh","p1"]]'.
preview() { # ... [body-tiers] [head]
  jq -nc --argjson id "$1" --arg t "$2" --argjson f "$3" --argjson bt "${4:-[]}" --arg h "${5:-$HEAD_A}" '
    {id: $id, submitted_at: $t, commit_id: $h, body_tiers: $bt,
     root_findings: [$f | to_entries[] | {comment_id: ($id * 10 + .key), path: .value[0], tier: .value[1]}],
     reply_comments: 0, reply_markers: []}'
}
rebut() { jq -nc --argjson f "$1" --arg p "$2" --arg t "$3" '{finding: $f, path: (if $p == "null" then null else $p end), at: $t, sources: ["tag"]}'; }
# stops <ledger-inputs> <rebuttals-json> <max>
stops() {
  local l
  l=$(crl_ledger "$(printf '%s' "$1" | jq -c --argjson rb "$2" '.rebuttals = $rb')") || return 1
  l=$(printf '%s' "$l" | jq -c --argjson m "$3" '.max_blocking_reviews = $m') || return 1
  crl_human_stops "$l" "$HEAD_A" nathanjohnpayne "$3" "${4:-}"
}
stop_check() { # <name> <stops-json> <predicate>
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass "$1"; else fail "$1: $3 failed on $2"; fi
}

R4=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 2 2026-09-25T01:00:00Z)" \
     "$(req 3 2026-09-25T02:00:00Z)" "$(req 4 2026-09-25T03:00:00Z)" | arr)
CCBB=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[]')" "$(preview 11 2026-09-25T01:10:00Z '[]')" \
     "$(preview 12 2026-09-25T02:10:00Z '[["a.sh","p1"]]')" "$(preview 13 2026-09-25T03:10:00Z '[["b.sh","p1"]]')" | arr)
IN=$(inputs "$R4" "$CCBB" '[]' '[]' '[]')
OUT=$(stops "$IN" '[]' 2)
stop_check "stops: clean, clean, blocking, blocking with a budget of 2 spends the blocking budget" "$OUT" \
  '.blocking_reviews == 2 and .stops == ["blocking-budget"]'
OUT=$(stops "$IN" '[]' 3)
stop_check "stops: the same history with a budget of 3 has no human stop" "$OUT" '.blocking_reviews == 2 and .stops == []'
# Runaway (#1560 canary, finding 1): a request ceiling below the budget is
# reached with every allowed request drawing a blocking review. Ceiling 2 with
# the default budget of 10 and two blocking reviews is a runaway, not cost
# exhaustion; ceiling 3 with the same two is not.
R2B=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 2 2026-09-25T01:00:00Z)" | arr)
BB=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
IN2=$(inputs "$R2B" "$BB" '[]' '[]' '[]')
stop_check "stops: two blocking reviews at a request ceiling of 2 under a budget of 10 are a runaway" \
  "$(stops "$IN2" '[]' 10 2)" '.stops == ["runaway"] and .request_ceiling == 2'
stop_check "stops: the same two at a ceiling of 3 are no runaway" "$(stops "$IN2" '[]' 10 3)" '.stops == []'
# A CodeRabbit failover request spends no ceiling (#2534), so it is no runaway
# window either: matchline#581's two blocking rounds, one of them the failover,
# are one deliberate request of two. A third, deliberate, blocking request then
# completes the runaway.
R2F=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z | jq -c '.ceiling_exempt = true')" "$(req 2 2026-09-25T01:00:00Z)" | arr)
stop_check "stops: a failover request is not a runaway window" "$(stops "$(inputs "$R2F" "$BB" '[]' '[]' '[]')" '[]' 10 2)" \
  '.stops == [] and .counted_requests == 1 and .blocking_windows == 1'
R3F=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z | jq -c '.ceiling_exempt = true')" "$(req 2 2026-09-25T01:00:00Z)" "$(req 3 2026-09-25T02:00:00Z)" | arr)
BBB_F=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" \
  "$(preview 12 2026-09-25T02:10:00Z '[["c.sh","p1"]]' '[]' "$HEAD_B")" | arr)
stop_check "stops: two deliberate blocking requests after a failover are a runaway" "$(stops "$(inputs "$R3F" "$BBB_F" '[]' '[]' '[]')" '[]' 10 2)" \
  '.stops == ["runaway"] and .counted_requests == 2 and .blocking_windows == 2'
stop_check "stops: the failover response still counts toward the blocking budget" "$(stops "$(inputs "$R3F" "$BBB_F" '[]' '[]' '[]')" '[]' 3 2)" \
  '.stops == ["blocking-budget"] and .blocking_reviews == 3'
L_F=$(crl_ledger "$(inputs "$R2F" "$BB" '[]' '[]' '[]' | jq -c '.rebuttals = []')" | jq -c '.max_blocking_reviews = 10')
if printf '%s' "$L_F" | jq -e '[.requests[].ceiling_exempt] == [true, false]' >/dev/null; then
  pass "stops: the ledger carries ceiling_exempt through"
else
  fail "stops: the ledger dropped ceiling_exempt: $(printf '%s' "$L_F" | jq -c '[.requests[] | {id, ceiling_exempt}]')"
fi
if crl_human_stops "$(printf '%s' "$L_F" | jq -c '.requests[0].ceiling_exempt = "yes"')" "$HEAD_A" nathanjohnpayne 10 2 >/dev/null; then
  fail "stops: a malformed ceiling_exempt was read"
else
  pass "stops: a malformed ceiling_exempt fails closed"
fi
stop_check "stops: a ledger without ceiling_exempt counts every author request" \
  "$(crl_human_stops "$(printf '%s' "$L_F" | jq -c 'del(.requests[].ceiling_exempt)')" "$HEAD_A" nathanjohnpayne 10 2)" '.stops == ["runaway"]'

# A blocking response whose every blocking finding was fixed is no runaway
# window (#2534, option B). Fixed needs all three: a fix disposition (.fixes),
# a later head descending from the reviewed one that changed the file
# (.head_changes), and an attributed Codex response on that later head that
# does not re-raise the path. matchline#581's shape: request 1 found a.sh
# (finding 100, HEAD_A), request 2 on HEAD_B found a different bug in b.sh
# (finding 110). Each case below changes one thing.
# fx_stops <ledger-inputs> <fixes> <head-changes> [ceiling] [rebuttals]
fx_stops() {
  local l
  l=$(crl_ledger "$(printf '%s' "$1" | jq -c --argjson rb "${5:-[]}" '.rebuttals = $rb')" \
    | jq -c --argjson fx "$2" --argjson hc "$3" '.max_blocking_reviews = 10 | .fixes = $fx | .head_changes = $hc') || return 1
  crl_human_stops "$l" "$HEAD_A" nathanjohnpayne 10 "${4:-2}"
}
hc() { # <base> <head> <status> <files-json>
  jq -nc --arg b "$1" --arg h "$2" --arg s "$3" --argjson f "$4" '[{base: $b, head: $h, status: $s, files: $f}]'
}
HC_AB=$(hc "$HEAD_A" "$HEAD_B" ahead '["a.sh"]')
stop_check "fixed: a fixed, unre-raised finding is no runaway window" "$(fx_stops "$IN2" '[100]' "$HC_AB")" \
  '.stops == [] and .fixed_responses == ["w1.0"] and .blocking_windows == 1 and .counted_requests == 2'
stop_check "fixed: the blocking budget still counts the fixed response" "$(fx_stops "$IN2" '[100]' "$HC_AB")" '.blocking_reviews == 2'
fx_no() { # <name> <stops-json>
  stop_check "fixed: $1 keeps the runaway" "$2" '.stops == ["runaway"] and .fixed_responses == []'
}
fx_no "no fix disposition" "$(fx_stops "$IN2" '[]' "$HC_AB")"
fx_no "a disposition on another finding" "$(fx_stops "$IN2" '[110]' "$HC_AB")"
fx_no "no recorded head change" "$(fx_stops "$IN2" '[100]' '[]')"
fx_no "a later head that did not change the file" "$(fx_stops "$IN2" '[100]' "$(hc "$HEAD_A" "$HEAD_B" ahead '["other.sh"]')")"
fx_no "a later head that does not descend from the reviewed one" "$(fx_stops "$IN2" '[100]' "$(hc "$HEAD_A" "$HEAD_B" diverged '["a.sh"]')")"
fx_no "an unreadable compare" "$(fx_stops "$IN2" '[100]' "$(hc "$HEAD_A" "$HEAD_B" unreadable '[]')")"
fx_no "a change recorded for other heads" "$(fx_stops "$IN2" '[100]' "$(hc "$HEAD_C" "$HEAD_B" ahead '["a.sh"]')")"
fx_no "a rebutted finding" "$(fx_stops "$IN2" '[100]' "$HC_AB" 2 "$(rebut 100 a.sh 2026-09-25T00:20:00Z | arr)" | jq -c '.stops |= map(select(. == "runaway"))')"
# Codex re-raised the path on the later head.
BB_RE=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["a.sh","p1"]]' '[]' "$HEAD_B")" | arr)
fx_no "a later blocking finding on the same path" "$(fx_stops "$(inputs "$R2B" "$BB_RE" '[]' '[]' '[]')" '[100]' "$HC_AB")"
# A later blocking finding Codex left unlocated may be the same one.
BB_UN=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[]' '["p1"]' "$HEAD_B")" | arr)
fx_no "a later unlocated blocking finding" "$(fx_stops "$(inputs "$R2B" "$BB_UN" '[]' '[]' '[]')" '[100]' "$HC_AB")"
# The later look must be on a later head.
BB_SAME=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]')" | arr)
fx_no "a later response on the same head" "$(fx_stops "$(inputs "$R2B" "$BB_SAME" '[]' '[]' '[]')" '[100]' "$(hc "$HEAD_A" "$HEAD_A" ahead '["a.sh"]')")"
# The later look must be attributed: two responses in one window are ambiguous.
BB_AMB=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" \
  "$(preview 12 2026-09-25T01:20:00Z '[["c.sh","p1"]]' '[]' "$HEAD_B")" | arr)
fx_no "a later response the ledger cannot attribute" "$(fx_stops "$(inputs "$R2B" "$BB_AMB" '[]' '[]' '[]')" '[100]' "$HC_AB")"
# A response with a body finding, or one of two findings unfixed, is not fixed.
BB_BODY=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]' '["p1"]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
fx_no "a response that also has a body finding" "$(fx_stops "$(inputs "$R2B" "$BB_BODY" '[]' '[]' '[]')" '[100]' "$HC_AB")"
BB_TWO=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"],["d.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
fx_no "a response with one of two findings unfixed" "$(fx_stops "$(inputs "$R2B" "$BB_TWO" '[]' '[]' '[]')" '[100]' "$(hc "$HEAD_A" "$HEAD_B" ahead '["a.sh","d.sh"]')")"
stop_check "fixed: both findings fixed clears the response" \
  "$(fx_stops "$(inputs "$R2B" "$BB_TWO" '[]' '[]' '[]')" '[100,101]' "$(hc "$HEAD_A" "$HEAD_B" ahead '["a.sh","d.sh"]')")" '.stops == []'
# The last round has no later look, so it always counts: with three rounds at a
# ceiling of 3, the first two fixed, one window remains and there is no runaway;
# with nothing fixed, all three count.
R3B=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 2 2026-09-25T01:00:00Z)" "$(req 3 2026-09-25T02:00:00Z)" | arr)
BBB3=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" \
  "$(preview 12 2026-09-25T02:10:00Z '[["c.sh","p1"]]' '[]' "$HEAD_C")" | arr)
HC3=$(jq -nc --arg a "$HEAD_A" --arg b "$HEAD_B" --arg c "$HEAD_C" '[{base: $a, head: $b, status: "ahead", files: ["a.sh"]},
  {base: $a, head: $c, status: "ahead", files: ["a.sh", "b.sh"]}, {base: $b, head: $c, status: "ahead", files: ["b.sh"]}]')
stop_check "fixed: two fixed rounds before a third leave one runaway window" "$(fx_stops "$(inputs "$R3B" "$BBB3" '[]' '[]' '[]')" '[100,110,120]' "$HC3" 3)" \
  '.stops == [] and .fixed_responses == ["w1.0","w2.0"] and .blocking_windows == 1'
stop_check "fixed: the same three rounds with nothing fixed are a runaway" "$(fx_stops "$(inputs "$R3B" "$BBB3" '[]' '[]' '[]')" '[]' "$HC3" 3)" \
  '.stops == ["runaway"] and .blocking_windows == 3'
# #2746: a fixed round leaves the request side of the comparison too. One
# fixed round followed by two blocking rounds at a ceiling of 2 is a runaway;
# before the fix the fixed round's request kept blocking_windows (2) below
# counted_requests (3) forever, so only blocking-budget could stop the loop.
stop_check "fixed: a fixed round then two blocking rounds at a ceiling of 2 are a runaway" \
  "$(fx_stops "$(inputs "$R3B" "$BBB3" '[]' '[]' '[]')" '[100]' "$HC3" 2)" \
  '.stops == ["runaway"] and .fixed_responses == ["w1.0"] and .blocking_windows == 2 and .counted_requests == 3'
stop_check "fixed: a fixed round then one blocking round at a ceiling of 2 are no runaway" \
  "$(fx_stops "$IN2" '[100]' "$HC_AB" 2)" '.stops == [] and .counted_requests == 2'
# A request in the same second as the round's last signal is not later, even
# when a fractional timestamp would sort it after ("00Z" > "00.5Z").
L_FS=$(crl_ledger "$(printf '%s' "$IN2" | jq -c '.rebuttals = []')" \
  | jq -c --argjson hc "$HC_AB" '.max_blocking_reviews = 10 | .fixes = [100] | .head_changes = $hc
          | .responses[0].last_at = "2026-09-25T01:00:00.5Z"')
stop_check "fixed: a same-second request does not read as later than the round" \
  "$(crl_human_stops "$L_FS" "$HEAD_A" nathanjohnpayne 10 2)" '.stops == ["runaway"] and .fixed_responses == []'
stop_check "fixed: an unreadable round time proves nothing" \
  "$(crl_human_stops "$(printf '%s' "$L_FS" | jq -c '.responses[0].last_at = "soon"')" "$HEAD_A" nathanjohnpayne 10 2)" '.stops == ["runaway"] and .fixed_responses == []'
# Malformed evidence fails; an older ledger without it reads as nothing fixed.
L_FX=$(crl_ledger "$(printf '%s' "$IN2" | jq -c '.rebuttals = []')" | jq -c --argjson hc "$HC_AB" '.max_blocking_reviews = 10 | .fixes = [100] | .head_changes = $hc')
for _bad in '.fixes = ["100"]' '.head_changes = [{base: 1}]' '.head_changes = "x"' '.responses[0].blocking_findings = [{id: "x"}]'; do
  if crl_human_stops "$(printf '%s' "$L_FX" | jq -c "$_bad")" "$HEAD_A" nathanjohnpayne 10 2 >/dev/null; then
    fail "fixed: malformed evidence ($_bad) was read"
  else
    pass "fixed: malformed evidence ($_bad) fails closed"
  fi
done
stop_check "fixed: a ledger without fixed-finding evidence counts every round" \
  "$(crl_human_stops "$(printf '%s' "$L_FX" | jq -c 'del(.fixes, .head_changes, .responses[].blocking_findings)')" "$HEAD_A" nathanjohnpayne 10 2)" '.stops == ["runaway"]'
stop_check "stops: a spent blocking budget names blocking-budget, not runaway" "$(stops "$IN2" '[]' 2 2)" '.stops == ["blocking-budget"]'
# Runaway counts request windows, not responses (#1584): two blocking reviews
# both answering the FIRST request, with a second request that drew nothing,
# is one blocking window out of a ceiling of 2, so no runaway.
BB1=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 12 2026-09-25T00:20:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
# ...and only windows opened by counted (author) requests (#1584): a blocking
# response to a FOREIGN request does not make the author's ceiling a runaway.
R2F=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 3 2026-09-25T00:30:00Z null false)" "$(req 2 2026-09-25T01:00:00Z)" | arr)
BBF=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 12 2026-09-25T00:40:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
stop_check "stops: a blocking response to a foreign request is no runaway window" \
  "$(stops "$(inputs "$R2F" "$BBF" '[]' '[]' '[]')" '[]' 10 2)" '.stops == [] and .blocking_windows == 1'
stop_check "stops: two blocking responses in one request window are no runaway at a ceiling of 2" \
  "$(stops "$(inputs "$R2B" "$BB1" '[]' '[]' '[]')" '[]' 10 2)" '.stops == [] and .blocking_reviews == 2 and .blocking_windows == 1'
# ...and every counted request must have drawn one (#1584): three author
# requests, the first answered clean and the next two blocking, are two
# blocking windows that reach a ceiling of 2, but not every request
# blocked, so no runaway.
R3=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 2 2026-09-25T01:00:00Z)" "$(req 3 2026-09-25T02:00:00Z)" | arr)
CBB=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[]')" "$(preview 11 2026-09-25T01:10:00Z '[["a.sh","p1"]]')" \
     "$(preview 12 2026-09-25T02:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
stop_check "stops: a clean first request is no runaway when more requests than the ceiling exist" \
  "$(stops "$(inputs "$R3" "$CBB" '[]' '[]' '[]')" '[]' 10 2)" '.stops == [] and .blocking_windows == 2 and .counted_requests == 3'
BBB=$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["c.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["a.sh","p1"]]')" \
     "$(preview 12 2026-09-25T02:10:00Z '[["b.sh","p1"]]' '[]' "$HEAD_B")" | arr)
stop_check "stops: every one of three requests blocking past a ceiling of 2 is a runaway" \
  "$(stops "$(inputs "$R3" "$BBB" '[]' '[]' '[]')" '[]' 10 2)" '.stops == ["runaway"] and .blocking_windows == 3 and .counted_requests == 3'
# A request without a boolean counted fails the ledger rather than reading as
# foreign, which would hide a runaway (#1584 Phase 4b P2).
for _bad in 'del(.requests[0].counted)' '.requests[1].counted = "yes"' '.requests[0].counted = null'; do
  _bl=$(crl_ledger "$(inputs "$R2B" "$BB" '[]' '[]' '[]')" | jq -c '.max_blocking_reviews = 10')
  if crl_human_stops "$(printf '%s' "$_bl" | jq -c "$_bad")" "$HEAD_A" nathanjohnpayne 10 2 >/dev/null; then
    fail "stops: a request with a malformed counted ($_bad) was accepted"
  else
    pass "stops: a request with a malformed counted ($_bad) fails the ledger"
  fi
done

L=$(crl_ledger "$(printf '%s' "$IN" | jq -c '.rebuttals = []')")
[ "$(crl_blocking_count "$L" "$HEAD_A" nathanjohnpayne)" = 2 ] \
  && pass "count: crl_blocking_count agrees with the human-stop count" \
  || fail "count: crl_blocking_count gave $(crl_blocking_count "$L" "$HEAD_A" nathanjohnpayne)"
if ! crl_blocking_count "$L" "$HEAD_B" nathanjohnpayne >/dev/null && ! crl_blocking_count "$L" "$HEAD_A" someone >/dev/null \
   && ! crl_human_stops "$(printf '%s' "$L" | jq -c '.max_blocking_reviews = 10')" "$HEAD_B" nathanjohnpayne 10 >/dev/null; then
  pass "count: a ledger for another head or author fails"
else
  fail "count: a ledger for another head or author was accepted"
fi
L10=$(printf '%s' "$L" | jq -c '.max_blocking_reviews = 10')
if crl_human_stops "$L10" "$HEAD_A" nathanjohnpayne 10 >/dev/null \
   && ! crl_human_stops "$L10" "$HEAD_A" nathanjohnpayne 9 >/dev/null \
   && ! crl_human_stops "$L" "$HEAD_A" nathanjohnpayne 10 >/dev/null \
   && ! crl_human_stops "$(printf '%s\n%s\n' "$L10" "$L10")" "$HEAD_A" nathanjohnpayne 10 >/dev/null \
   && ! crl_blocking_count "$(printf '%s\n%s\n' "$L" "$L")" "$HEAD_A" nathanjohnpayne >/dev/null; then
  pass "count: two ledger documents, or a budget from another policy snapshot (or none), fail"
else
  fail "count: a second document or a mismatched snapshot budget was accepted"
fi
if ! crl_human_stops "$(printf '%s' "$L10" | jq -c '.rebuttals = [{finding: "x", path: null, at: "t"}]')" "$HEAD_A" nathanjohnpayne 10 >/dev/null \
   && ! crl_human_stops "$(printf '%s' "$L10" | jq -c 'del(.rebuttals)')" "$HEAD_A" nathanjohnpayne 10 >/dev/null \
   && ! crl_blocking_count "$(printf '%s' "$L" | jq -c '.responses[0].class = null')" "$HEAD_A" nathanjohnpayne >/dev/null \
   && ! crl_blocking_count "$(printf '%s' "$L" | jq -c '.responses[0].class = "severe"')" "$HEAD_A" nathanjohnpayne >/dev/null \
   && ! crl_blocking_count "$(printf '%s' "$L" | jq -c '.responses[0].first_at = null')" "$HEAD_A" nathanjohnpayne >/dev/null; then
  pass "count: malformed rebuttals or responses fail"
else
  fail "count: malformed rebuttals or responses were accepted"
fi

# Unsolicited blocking review (before any request) is not counted.
IN=$(inputs "$(req 1 2026-09-25T01:00:00Z | arr)" \
  "$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["a.sh","p1"]]')" "$(preview 11 2026-09-25T01:10:00Z '[["a.sh","p1"]]')" | arr)" '[]' '[]' '[]')
stop_check "stops: an unsolicited blocking review is not counted" "$(stops "$IN" '[]' 2)" '.blocking_reviews == 1 and .stops == []'

# Rebuttals. One request drew a blocking finding on x.sh; it was rebutted.
R2=$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 2 2026-09-25T02:00:00Z)" | arr)
FIRST=$(preview 10 2026-09-25T00:10:00Z '[["x.sh","p1"]]')
RB=$(rebut 100 x.sh 2026-09-25T01:00:00Z | arr)
IN=$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' '[]')
stop_check "stops: a rebuttal with no Codex response after it is untested" "$(stops "$IN" "$RB" 10)" \
  '.stops == ["untested-rebuttal"] and .untested_rebuttals[0].finding == 100'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[]' '[]' "$HEAD_B")" | arr)" '[]' '[]' '[]')
stop_check "stops: a rebuttal Codex answered clean, provably to the later request, is settled" "$(stops "$IN" "$RB" 10)" '.stops == []'
# A PR reaction is not a response and cannot test any rebuttal.
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" '[]' "$(reaction 900 2026-09-25T02:10:00Z | arr)" '[]')
stop_check "stops: a PR reaction leaves the rebuttal untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
# Malformed observed fields remain anchorless, so a later clean comment
# cannot fabricate a distinct head and claim it tested the rebuttal.
for token in zzzzzz "${HEAD_A}-not-a-sha" "${HEAD_A}a"; do
  C=$(jq -nc --arg token "$token" '[{id:901,user:{login:"chatgpt-codex-connector[bot]"},created_at:"2026-09-25T02:10:00Z",body:("Codex Review: Didn\u0027t find any major issues.\nReviewed commit: " + $token)}]')
  V=$(crqe_verdicts "$C" 'chatgpt-codex-connector[bot]')
  IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" "$V" '[]' '[]')
  stop_check "malformed verdict $token leaves the rebuttal untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
done

# Even in the first and only request window, a reaction cannot be attributed
# as a clean response to clear an earlier rebuttal at a spent request ceiling.
IN=$(inputs "$(req 1 2026-09-25T02:00:00Z | arr)" '[]' '[]' "$(reaction 900 2026-09-25T02:10:00Z | arr)" '[]')
L=$(crl_ledger "$IN")
check "a reaction-only first request remains unanswered" "$L" \
  '.summary.responses == 0 and .requests[0].outcome == "no_response_yet"'
stop_check "stops: a reaction-only first window cannot clear an earlier rebuttal" "$(stops "$IN" "$RB" 10 1)" \
  '.stops == ["untested-rebuttal"]'

# A response that lands after the rebuttal but answers a request posted before
# it cannot have read the rebuttal (#1579): the only request predates it.
IN=$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T01:30:00Z '[]')" | arr)" '[]' '[]' '[]')
stop_check "stops: a response to a request already in flight before the rebuttal leaves it untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
# A provider-block notice after the rebuttal is not Codex re-reading it (#1579).
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' "$(block 901 2026-09-25T02:10:00Z usage_limit | arr)")
stop_check "stops: a provider-block notice after a rebuttal leaves it untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
# A response in the same second as the rebuttal cannot be shown to have read
# it, so the rebuttal stays untested.
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[]' '[]' "$HEAD_B")" | arr)" '[]' '[]' '[]')
stop_check "stops: a response in the same second as the rebuttal leaves it untested" \
  "$(stops "$IN" "$(rebut 100 x.sh 2026-09-25T02:10:00Z | arr)" 10)" '.stops == ["untested-rebuttal"]'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["x.sh","p1"]]')" | arr)" '[]' '[]' '[]')
stop_check "stops: a later blocking finding on the rebutted path is a disagreement" "$(stops "$IN" "$RB" 10)" \
  '.stops == ["disagreement"] and .disagreements[0].finding == 100'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["y.sh","p1"]]' '[]' "$HEAD_B")" | arr)" '[]' '[]' '[]')
# A re-raise can move with a rename, so path cannot rule a repeat out: any
# counted response to a later request after a rebuttal is a disagreement
# (#1560 canary, finding 3; this case asserted the opposite before).
stop_check "stops: a later blocking finding on another path is still a disagreement" "$(stops "$IN" "$RB" 10)" '.stops == ["disagreement"]'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["x.sh","p2"]]' '[]' "$HEAD_B")" | arr)" '[]' '[]' '[]')
stop_check "stops: a later discretionary finding on the rebutted path is not a disagreement" "$(stops "$IN" "$RB" 10)" '.stops == []'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[]' '["p1"]')" | arr)" '[]' '[]' '[]')
stop_check "stops: a later blocking body finding cannot be located, so it is a disagreement" "$(stops "$IN" "$RB" 10)" '.stops == ["disagreement"]'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" "$(verdict 901 2026-09-25T02:10:00Z '[]' false | arr)" '[]' '[]')
stop_check "stops: a later unknown-tier response is a disagreement" "$(stops "$IN" "$RB" 10)" '.stops == ["disagreement"]'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["y.sh","p1"]]')" | arr)" '[]' '[]' '[]')
stop_check "stops: a rebuttal with no path matches any later blocking response" \
  "$(stops "$IN" "$(rebut 100 null 2026-09-25T01:00:00Z | arr)" 10)" '.stops == ["disagreement"]'
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["x.sh","p1"]]')" | arr)" '[]' '[]' '[]')
stop_check "stops: every stop that holds is reported, blocking budget first" "$(stops "$IN" "$RB" 2)" \
  '.stops == ["blocking-budget", "disagreement"]'

# ---- Owner tiebreak (#2511) ----------------------------------------------------

PR_URL=https://github.com/o/r/pull/1
# cm <id> <login> <created> <updated> <body>
cm() { jq -nc --argjson id "$1" --arg u "$2" --arg c "$3" --arg up "$4" --arg b "$5" \
  '{id: $id, user: {login: $u}, created_at: $c, updated_at: $up, body: $b}'; }
mark() { printf 'TIEBREAK_REBUTTAL_ACCEPTED=%s@%s#%s' "${2:-$PR_URL}" "${3:-$HEAD_A}" "$1"; }
# tb_stops <ledger-inputs> <rebuttals> <comments-json> -> applied stops
tb_stops() {
  local l st marks
  l=$(crl_ledger "$(printf '%s' "$1" | jq -c --argjson rb "$2" '.rebuttals = $rb')" | jq -c '.max_blocking_reviews = 10') || return 1
  st=$(crl_human_stops "$l" "$HEAD_A" nathanjohnpayne 10) || return 1
  marks=$(crl_owner_tiebreaks "$3" nathanjohnpayne "$PR_URL" "$HEAD_A") || return 1
  crl_apply_owner_tiebreaks "$st" "$l" "$marks"
}

# #579's shape: one blocking finding, rebutted, no Codex response afterwards.
IN=$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' '[]')
M100=$(mark 100)
C=$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$M100")" | arr)
stop_check "tiebreak: an owner marker for the finding clears an untested rebuttal" "$(tb_stops "$IN" "$RB" "$C")" \
  '.stops == [] and .untested_rebuttals == [] and .owner_tiebreaks == [{kind: "untested", finding: 100}]'
stop_check "tiebreak: markers on a multi-line comment, with CRLF and indentation, are read" \
  "$(tb_stops "$IN" "$RB" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(printf 'Accepting the rebuttal.\r\n  %s\r\n' "$M100")")" | arr)")" '.stops == []'
stop_check "tiebreak: the PR URL compares case-insensitively" \
  "$(tb_stops "$IN" "$RB" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(mark 100 HTTPS://GITHUB.COM/O/R/pull/1)")" | arr)")" '.stops == []'

# Everything below must leave the stop standing.
no_clear() { # <name> <comments-json>
  stop_check "tiebreak: $1 does not clear the stop" "$(tb_stops "$IN" "$RB" "$2")" \
    '.stops == ["untested-rebuttal"] and (.owner_tiebreaks | length) == 0'
}
no_clear "a marker by another account" "$(printf '%s\n' "$(cm 1 nathanpayne-claude 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$M100")" | arr)"
no_clear "an edited marker comment" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:05:00Z "$M100")" | arr)"
no_clear "a marker posted before the rebuttal" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T00:30:00Z 2026-09-25T00:30:00Z "$M100")" | arr)"
no_clear "a marker for another head" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(mark 100 "$PR_URL" "$HEAD_B")")" | arr)"
no_clear "a marker for another PR" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(mark 100 https://github.com/o/r/pull/2)")" | arr)"
no_clear "a marker for another finding" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(mark 101)")" | arr)"
no_clear "a marker quoted or fenced rather than on its own line" "$(printf '%s\n' \
  "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "> $M100")" \
  "$(cm 2 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "see $M100 for the rule")" \
  "$(cm 3 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "TIEBREAK_REBUTTAL_ACCEPTED=<PR-URL>@<full-head-sha>#<finding-id>")" | arr)"
no_clear "no comments" '[]'
if crl_owner_tiebreaks '{"not":"an array"}' nathanjohnpayne "$PR_URL" "$HEAD_A" >/dev/null; then
  fail "tiebreak: a comments payload that is not an array was accepted"
else
  pass "tiebreak: a comments payload that is not an array fails"
fi

# A budget stop is not a dispute: the marker never clears it.
IN3=$(inputs "$R4" "$CCBB" '[]' '[]' '[]')
l=$(crl_ledger "$(printf '%s' "$IN3" | jq -c '.rebuttals = []')" | jq -c '.max_blocking_reviews = 2')
st=$(crl_human_stops "$l" "$HEAD_A" nathanjohnpayne 2)
stop_check "tiebreak: a marker leaves blocking-budget standing" \
  "$(crl_apply_owner_tiebreaks "$st" "$l" "$(crl_owner_tiebreaks "$C" nathanjohnpayne "$PR_URL" "$HEAD_A")")" '.stops == ["blocking-budget"]'

# Disagreement: Codex re-raised after the rebuttal. A marker must be newer than
# the re-raise as well as the rebuttal.
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["x.sh","p1"]]')" | arr)" '[]' '[]' '[]')
stop_check "tiebreak: a marker older than the re-raise leaves a disagreement standing" \
  "$(tb_stops "$IN" "$RB" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T01:30:00Z 2026-09-25T01:30:00Z "$M100")" | arr)")" \
  '.stops == ["disagreement"] and (.owner_tiebreaks | length) == 0'
stop_check "tiebreak: a marker newer than the re-raise clears the disagreement" "$(tb_stops "$IN" "$RB" "$C")" \
  '.stops == [] and .disagreements == [] and .owner_tiebreaks == [{kind: "disagreement", finding: 100}]'

# A response group can gain a later signal after its first one; the marker must
# postdate that last signal too (CodeRabbit on #2515).
IN_D=$(inputs "$R2" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T02:10:00Z '[["x.sh","p1"]]')" | arr)" '[]' '[]' '[]')
L_D=$(crl_ledger "$(printf '%s' "$IN_D" | jq -c --argjson rb "$RB" '.rebuttals = $rb')" | jq -c '.max_blocking_reviews = 10')
if printf '%s' "$L_D" | jq -e 'all(.responses[]; .last_at >= .first_at)' >/dev/null; then
  pass "tiebreak: every response records last_at, never before first_at"
else
  fail "tiebreak: a response is missing last_at or has it before first_at"
fi
LATE=$(printf '%s' "$L_D" | jq -c '.responses |= map(if .first_at == "2026-09-25T02:10:00Z" then .last_at = "2026-09-25T03:30:00Z" else . end)')
ST_D=$(crl_human_stops "$LATE" "$HEAD_A" nathanjohnpayne 10)
stop_check "tiebreak: a marker older than a response's last signal leaves the disagreement standing" \
  "$(crl_apply_owner_tiebreaks "$ST_D" "$LATE" "$(crl_owner_tiebreaks "$C" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == ["disagreement"] and (.owner_tiebreaks | length) == 0'
stop_check "tiebreak: a ledger without last_at falls back to first_at" \
  "$(crl_apply_owner_tiebreaks "$ST_D" "$(printf '%s' "$LATE" | jq -c 'del(.responses[].last_at)')" "$(crl_owner_tiebreaks "$C" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == []'

# Two disputes: settling one leaves the other, and the stop names what remains.
IN=$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" \
  "$(printf '%s\n' "$(preview 10 2026-09-25T00:10:00Z '[["x.sh","p1"],["y.sh","p1"]]')" | arr)" '[]' '[]' '[]')
RB2=$(printf '%s\n' "$(rebut 100 x.sh 2026-09-25T01:00:00Z)" "$(rebut 101 y.sh 2026-09-25T01:00:00Z)" | arr)
stop_check "tiebreak: settling one of two rebuttals leaves the stop standing" "$(tb_stops "$IN" "$RB2" "$C")" \
  '.stops == ["untested-rebuttal"] and (.untested_rebuttals | map(.finding)) == [101]'
stop_check "tiebreak: a marker line per finding settles both" \
  "$(tb_stops "$IN" "$RB2" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(printf '%s\n%s' "$M100" "$(mark 101)")")" | arr)")" '.stops == []'

# ---- Owner tiebreak on a runaway (#2534) --------------------------------------

# matchline#581's shape: a request ceiling of 2, and each request drew a
# blocking review. The last signal is the second response, at 01:10.
rmark() { printf 'TIEBREAK_RUNAWAY_ACCEPTED=%s@%s' "${1:-$PR_URL}" "${2:-$HEAD_A}"; }
# rw_stops <ledger-inputs> <comments-json> [rebuttals] [max] -> applied stops
rw_stops() {
  local l st marks
  l=$(crl_ledger "$(printf '%s' "$1" | jq -c --argjson rb "${3:-[]}" '.rebuttals = $rb')" \
    | jq -c --argjson m "${4:-10}" '.max_blocking_reviews = $m') || return 1
  st=$(crl_human_stops "$l" "$HEAD_A" nathanjohnpayne "${4:-10}" 2) || return 1
  marks=$(crl_owner_tiebreaks "$2" nathanjohnpayne "$PR_URL" "$HEAD_A") || return 1
  crl_apply_owner_tiebreaks "$st" "$l" "$marks"
}
RM=$(rmark)
RWC=$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$RM")" | arr)
stop_check "runaway tiebreak: without a marker the runaway stands" "$(rw_stops "$IN2" '[]')" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
stop_check "runaway tiebreak: an owner runaway marker clears the runaway" "$(rw_stops "$IN2" "$RWC")" \
  '.stops == [] and .owner_tiebreaks == [{kind: "runaway"}]'
stop_check "runaway tiebreak: a marker on a multi-line comment, with CRLF and indentation, is read" \
  "$(rw_stops "$IN2" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(printf 'Both rounds found real bugs.\r\n  %s\r\n' "$RM")")" | arr)")" '.stops == []'
stop_check "runaway tiebreak: the PR URL compares case-insensitively" \
  "$(rw_stops "$IN2" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(rmark HTTPS://GITHUB.COM/O/R/pull/1)")" | arr)")" '.stops == []'

rw_no_clear() { # <name> <comments-json>
  stop_check "runaway tiebreak: $1 does not clear the runaway" "$(rw_stops "$IN2" "$2")" \
    '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
}
rw_no_clear "a marker by another account" "$(printf '%s\n' "$(cm 1 nathanpayne-claude 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$RM")" | arr)"
rw_no_clear "an edited marker comment" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:05:00Z "$RM")" | arr)"
rw_no_clear "a marker posted before the last request" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T00:30:00Z 2026-09-25T00:30:00Z "$RM")" | arr)"
rw_no_clear "a marker posted after the last request but before its response" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T01:05:00Z 2026-09-25T01:05:00Z "$RM")" | arr)"
rw_no_clear "a marker in the same second as the last response" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T01:10:00Z 2026-09-25T01:10:00Z "$RM")" | arr)"
rw_no_clear "a marker for another head" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(rmark "$PR_URL" "$HEAD_B")")" | arr)"
rw_no_clear "a marker for another PR" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(rmark https://github.com/o/r/pull/2)")" | arr)"
rw_no_clear "a marker with a finding suffix" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$RM#100")" | arr)"
rw_no_clear "a rebuttal marker" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(mark 100)")" | arr)"
rw_no_clear "a marker quoted, in prose, or as a placeholder" "$(printf '%s\n' \
  "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "> $RM")" \
  "$(cm 2 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "see $RM for the rule")" \
  "$(cm 3 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "TIEBREAK_RUNAWAY_ACCEPTED=<PR-URL>@<full-head-sha>")" | arr)"
rw_no_clear "no comments" '[]'

# A response group that gains a later signal moves the floor with it.
L_RW=$(crl_ledger "$(printf '%s' "$IN2" | jq -c '.rebuttals = []')" | jq -c '.max_blocking_reviews = 10 | .responses[-1].last_at = "2026-09-25T03:30:00Z"')
stop_check "runaway tiebreak: a marker older than a response's last signal leaves the runaway standing" \
  "$(crl_apply_owner_tiebreaks "$(crl_human_stops "$L_RW" "$HEAD_A" nathanjohnpayne 10 2)" "$L_RW" "$(crl_owner_tiebreaks "$RWC" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'

# A request posted after the runaway's last response moves the floor too.
IN2_LATE=$(inputs "$(printf '%s\n' "$(req 1 2026-09-25T00:00:00Z)" "$(req 2 2026-09-25T01:00:00Z)" "$(req 3 2026-09-25T02:00:00Z null false)" | arr)" "$BB" '[]' '[]' '[]')
stop_check "runaway tiebreak: a marker older than a later request leaves the runaway standing" \
  "$(rw_stops "$IN2_LATE" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T01:30:00Z 2026-09-25T01:30:00Z "$RM")" | arr)")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
stop_check "runaway tiebreak: a marker newer than that request clears the runaway" "$(rw_stops "$IN2_LATE" "$RWC")" \
  '.stops == [] and .owner_tiebreaks == [{kind: "runaway"}]'

# The runaway marker settles nothing else: a dispute or a spent blocking
# budget on the same head still stands.
stop_check "runaway tiebreak: a runaway marker leaves an untested rebuttal standing" \
  "$(tb_stops "$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' '[]')" "$RB" "$RWC")" \
  '.stops == ["untested-rebuttal"] and (.owner_tiebreaks | length) == 0'
RB_RW=$(rebut 110 b.sh 2026-09-25T01:30:00Z | arr)
stop_check "runaway tiebreak: with a runaway and an untested rebuttal, the marker clears only the runaway" \
  "$(rw_stops "$IN2" "$RWC" "$RB_RW")" \
  '.stops == ["untested-rebuttal"] and .owner_tiebreaks == [{kind: "runaway"}] and (.untested_rebuttals | map(.finding)) == [110]'
stop_check "runaway tiebreak: a rebuttal marker and a runaway marker together clear both" \
  "$(rw_stops "$IN2" "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:00Z 2026-09-25T03:00:00Z "$(printf '%s\n%s' "$RM" "$(mark 110)")")" | arr)" "$RB_RW")" \
  '.stops == [] and (.owner_tiebreaks | map(.kind) | sort) == ["runaway", "untested"]'
stop_check "runaway tiebreak: a runaway marker leaves blocking-budget standing" \
  "$(rw_stops "$IN2" "$RWC" '[]' 2)" '.stops == ["blocking-budget"] and (.owner_tiebreaks | length) == 0'

# Instants compare as whole seconds, never as text (#2561). ISO strings
# collate "...00Z" after "...00.5Z", and a non-instant string sorts above
# every real one, so a lexicographic test would release the stop on a
# same-second, fractional or malformed timestamp. The ledger grammar accepts
# a seconds fraction (#2528), so the floor can carry one.
L_RW_FRAC=$(printf '%s' "$L_RW" | jq -c '.responses[-1].last_at = "2026-09-25T03:00:00.5Z"')
ST_RW_FRAC=$(crl_human_stops "$L_RW_FRAC" "$HEAD_A" nathanjohnpayne 10 2)
rw_frac() { crl_apply_owner_tiebreaks "$ST_RW_FRAC" "$L_RW_FRAC" "$(crl_owner_tiebreaks "$1" nathanjohnpayne "$PR_URL" "$HEAD_A")"; }
stop_check "runaway tiebreak: a same-second marker does not outrank a fractional-second floor" "$(rw_frac "$RWC")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
stop_check "runaway tiebreak: a next-second marker postdates a fractional-second floor" \
  "$(rw_frac "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T03:00:01Z 2026-09-25T03:00:01Z "$RM")" | arr)")" \
  '.stops == [] and .owner_tiebreaks == [{kind: "runaway"}]'
rw_no_clear "a marker whose comment timestamp is not an instant" "$(printf '%s\n' "$(cm 1 nathanjohnpayne not-a-time not-a-time "$RM")" | arr)"
rw_no_clear "a marker whose comment timestamp sorts above every instant" "$(printf '%s\n' "$(cm 1 nathanjohnpayne zzzz-99-99T99:99:99Z zzzz-99-99T99:99:99Z "$RM")" | arr)"
stop_check "runaway tiebreak: a floor that is not an instant leaves the runaway standing" \
  "$(crl_apply_owner_tiebreaks "$ST_RW_FRAC" "$(printf '%s' "$L_RW_FRAC" | jq -c '.responses[-1].last_at = "later"')" "$(crl_owner_tiebreaks "$RWC" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
# A malformed candidate that is NOT the maximum ("!" sorts below every digit)
# must hold too: a textual max would discard it before the floor is checked
# (Codex on #2567).
# A trailing newline passes a `$`-anchored grammar in this regex dialect and
# fromdateiso8601 still converts it (Codex on #2567): the grammar must use
# absolute anchors so such a candidate holds even against a later marker.
stop_check "runaway tiebreak: a candidate with a trailing newline is malformed and holds against a later marker" \
  "$(crl_apply_owner_tiebreaks "$ST_RW_FRAC" "$(printf '%s' "$L_RW_FRAC" | jq -c '.responses[-1].last_at = "2026-09-25T03:00:00Z\n"')" "$(crl_owner_tiebreaks "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T04:00:00Z 2026-09-25T04:00:00Z "$RM")" | arr)" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
stop_check "runaway tiebreak: a marker whose own timestamp carries a trailing newline does not clear" \
  "$(rw_frac "$(printf '%s\n' "$(cm 1 nathanjohnpayne $'2026-09-25T04:00:00Z\n' $'2026-09-25T04:00:00Z\n' "$RM")" | arr)")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
stop_check "runaway tiebreak: a malformed candidate below the maximum still leaves the runaway standing" \
  "$(crl_apply_owner_tiebreaks "$ST_RW_FRAC" "$(printf '%s' "$L_RW_FRAC" | jq -c '.responses[0].last_at = "!"')" "$(crl_owner_tiebreaks "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T04:00:00Z 2026-09-25T04:00:00Z "$RM")" | arr)" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'
# last_at feeds the floor, so a non-string value fails the ledger rather than
# dropping that response out of the floor; an absent last_at still falls back
# to first_at (L_RW's last response: last_at 03:30, first_at 01:10).
# An explicit null is present and malformed (CodeRabbit on #2567): falling back
# to first_at would move the floor earlier, so it fails; only an ABSENT key
# falls back.
for _bad_last in '.responses[-1].last_at = 5' '.responses[-1].last_at = true' '.responses[-1].last_at = {}' '.responses[-1].last_at = null'; do
  if crl_human_stops "$(printf '%s' "$L_RW" | jq -c "$_bad_last")" "$HEAD_A" nathanjohnpayne 10 2 >/dev/null; then
    fail "runaway tiebreak: a response with a malformed last_at ($_bad_last) was accepted"
  else
    pass "runaway tiebreak: a response with a malformed last_at ($_bad_last) fails the ledger"
  fi
done
L_RW_NOLAST=$(printf '%s' "$L_RW" | jq -c 'del(.responses[].last_at)')
stop_check "runaway tiebreak: a response without last_at falls back to first_at for the floor" \
  "$(crl_apply_owner_tiebreaks "$(crl_human_stops "$L_RW_NOLAST" "$HEAD_A" nathanjohnpayne 10 2)" "$L_RW_NOLAST" "$(crl_owner_tiebreaks "$RWC" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == [] and .owner_tiebreaks == [{kind: "runaway"}]'
# The fallback floor is the response's first_at (01:10), later than the last
# request (01:00): a marker between the two must hold, or the fallback has
# dropped the response and only the requests set the floor (CodeRabbit on #2567).
stop_check "runaway tiebreak: under the absent-last_at fallback a marker after the last request but before first_at holds" \
  "$(crl_apply_owner_tiebreaks "$(crl_human_stops "$L_RW_NOLAST" "$HEAD_A" nathanjohnpayne 10 2)" "$L_RW_NOLAST" "$(crl_owner_tiebreaks "$(printf '%s\n' "$(cm 1 nathanjohnpayne 2026-09-25T01:05:00Z 2026-09-25T01:05:00Z "$RM")" | arr)" nathanjohnpayne "$PR_URL" "$HEAD_A")")" \
  '.stops == ["runaway"] and (.owner_tiebreaks | length) == 0'

# The barrier's own reader (p4b_codex_human_stops) applies markers it reads from
# the PR's comments, and leaves the stop standing when it cannot read them.
TB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ledger-tiebreak.XXXXXX")
IN=$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' '[]')
crl_ledger "$(printf '%s' "$IN" | jq -c --argjson rb "$RB" '.rebuttals = $rb')" \
  | jq -c '.max_blocking_reviews = 10 | .policy_fingerprint = "1-2"' >"$TB_DIR/ledger.json"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$TB_DIR/ledger.json" >"$TB_DIR/ledger-stub.sh"
chmod +x "$TB_DIR/ledger-stub.sh"
# barrier_stops <comments-json|FAIL>
barrier_stops() (
  # shellcheck source=../scripts/phase-4b/lib.sh
  . "$ROOT/scripts/phase-4b/lib.sh"
  p4b_config() { echo /dev/null; }
  p4b_top_field() { echo nathanjohnpayne; }
  p4b_pr_policy_tuple() { jq -nc --arg h "$HEAD_A" '{head_sha: $h, base_ref: "main", base_sha: "b", default_branch: "main"}'; }
  crqe_governing_budget() { jq -nc '{max_blocking_reviews: 10, max_request_attempts: 2, policy_fingerprint: "1-2"}'; }
  gh_api_array() { [ "$1" != FAIL ] || return 1; printf '%s' "$TB_COMMENTS"; }
  TB_COMMENTS=$1
  [ "$1" != FAIL ] || gh_api_array() { return 1; }
  P4B_CODEX_LEDGER="$TB_DIR/ledger-stub.sh" p4b_codex_human_stops o/r 1 "$HEAD_A"
)
stop_check "barrier: no marker leaves the untested rebuttal standing" "$(barrier_stops '[]')" \
  '.state == "stop" and .stops == ["untested-rebuttal"]'
stop_check "barrier: an owner marker on the PR clears it, and the result records the tiebreak" "$(barrier_stops "$C")" \
  '.state == "clear" and .stops == [] and .owner_tiebreaks == [{kind: "untested", finding: 100}]'
stop_check "barrier: unreadable comments leave the stop standing" "$(barrier_stops FAIL)" \
  '.state == "stop" and .stops == ["untested-rebuttal"]'
# The barrier reads markers when a runaway is the only stop, too (#2534): the
# stub budget's ceiling is 2, as on matchline.
crl_ledger "$(printf '%s' "$IN2" | jq -c '.rebuttals = []')" \
  | jq -c '.max_blocking_reviews = 10 | .policy_fingerprint = "1-2"' >"$TB_DIR/ledger.json"
stop_check "barrier: no marker leaves the runaway standing" "$(barrier_stops '[]')" \
  '.state == "stop" and .stops == ["runaway"]'
stop_check "barrier: an owner runaway marker on the PR clears it, and the result records the tiebreak" "$(barrier_stops "$RWC")" \
  '.state == "clear" and .stops == [] and .owner_tiebreaks == [{kind: "runaway"}]'
stop_check "barrier: unreadable comments leave the runaway standing" "$(barrier_stops FAIL)" \
  '.state == "stop" and .stops == ["runaway"]'

# ---- Resolved stops: the one consumer-facing calculation (#2558) -------------
# crl_resolved_human_stops is what the Phase 4b barrier and Cockpit both call:
# crl_human_stops with the owner's markers applied. It reads the comments
# through the command it is given, only when a dispute or runaway stop holds,
# and a failed read leaves the stop standing.
rs_read() { printf 'read\n' >>"$TB_DIR/rs-reads"; printf '%s' "$1"; }
rs_fail() { printf 'read\n' >>"$TB_DIR/rs-reads"; return 1; }
rs_reads() { if [ -f "$TB_DIR/rs-reads" ]; then wc -l <"$TB_DIR/rs-reads" | tr -d ' '; else printf 0; fi; }
RS_RW=$(crl_ledger "$(printf '%s' "$IN2" | jq -c '.rebuttals = []')" | jq -c '.max_blocking_reviews = 10')
stop_check "resolved: an owner runaway marker releases the runaway, and the result records it" \
  "$(crl_resolved_human_stops "$RS_RW" "$HEAD_A" nathanjohnpayne 10 2 "$PR_URL" rs_read "$RWC")" \
  '.stops == [] and .owner_tiebreaks == [{kind: "runaway"}] and .blocking_windows == 2'
stop_check "resolved: no marker leaves the runaway standing, with an empty tiebreak record" \
  "$(crl_resolved_human_stops "$RS_RW" "$HEAD_A" nathanjohnpayne 10 2 "$PR_URL" rs_read '[]')" \
  '.stops == ["runaway"] and .owner_tiebreaks == []'
stop_check "resolved: unreadable comments leave the runaway standing, with no tiebreak record" \
  "$(crl_resolved_human_stops "$RS_RW" "$HEAD_A" nathanjohnpayne 10 2 "$PR_URL" rs_fail)" \
  '.stops == ["runaway"] and (has("owner_tiebreaks") | not)'
stop_check "resolved: a comments payload that is not one array leaves the runaway standing" \
  "$(crl_resolved_human_stops "$RS_RW" "$HEAD_A" nathanjohnpayne 10 2 "$PR_URL" rs_read '{"not":"an array"}')" \
  '.stops == ["runaway"] and (has("owner_tiebreaks") | not)'
stop_check "resolved: no reader at all leaves the runaway standing" \
  "$(crl_resolved_human_stops "$RS_RW" "$HEAD_A" nathanjohnpayne 10 2 "$PR_URL")" \
  '.stops == ["runaway"] and (has("owner_tiebreaks") | not)'
RS_D=$(crl_ledger "$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' '[]' \
  | jq -c --argjson rb "$RB" '.rebuttals = $rb')" | jq -c '.max_blocking_reviews = 10')
stop_check "resolved: an owner rebuttal marker releases an untested rebuttal" \
  "$(crl_resolved_human_stops "$RS_D" "$HEAD_A" nathanjohnpayne 10 "" "$PR_URL" rs_read "$C")" \
  '.stops == [] and .untested_rebuttals == [] and .owner_tiebreaks == [{kind: "untested", finding: 100}]'
stop_check "resolved: a runaway marker releases no dispute" \
  "$(crl_resolved_human_stops "$RS_D" "$HEAD_A" nathanjohnpayne 10 "" "$PR_URL" rs_read "$RWC")" \
  '.stops == ["untested-rebuttal"] and .owner_tiebreaks == []'
# With no releasable stop the reader never runs and the output is crl_human_stops' own.
RS_CLEAN=$(crl_ledger "$(inputs "$R4" "$CCBB" '[]' '[]' '[]' | jq -c '.rebuttals = []')" | jq -c '.max_blocking_reviews = 10')
RS_BUDGET=$(printf '%s' "$RS_CLEAN" | jq -c '.max_blocking_reviews = 2')
reads_before=$(rs_reads)
OUT=$(crl_resolved_human_stops "$RS_CLEAN" "$HEAD_A" nathanjohnpayne 10 20 "$PR_URL" rs_fail)
if [ "$OUT" = "$(crl_human_stops "$RS_CLEAN" "$HEAD_A" nathanjohnpayne 10 20)" ] \
   && printf '%s' "$OUT" | jq -e '.stops == [] and (has("owner_tiebreaks") | not)' >/dev/null; then
  pass "resolved: with no stop the output is crl_human_stops' own"
else
  fail "resolved: the no-stop output differs from crl_human_stops: $OUT"
fi
stop_check "resolved: a spent blocking budget alone is not releasable" \
  "$(crl_resolved_human_stops "$RS_BUDGET" "$HEAD_A" nathanjohnpayne 2 20 "$PR_URL" rs_fail)" \
  '.stops == ["blocking-budget"] and (has("owner_tiebreaks") | not)'
if OUT=$(crl_resolved_human_stops '{"not":"a ledger"}' "$HEAD_A" nathanjohnpayne 10 2 "$PR_URL" rs_read "$RWC") || [ -n "$OUT" ]; then
  fail "resolved: a malformed ledger was accepted: $OUT"
else
  pass "resolved: a malformed ledger fails, printing nothing"
fi
if [ "$(rs_reads)" = "$reads_before" ]; then
  pass "resolved: with no dispute or runaway stop, or no ledger, the comments are never read"
else
  fail "resolved: the comments were read with nothing to release ($reads_before -> $(rs_reads))"
fi

# ---- Part 2: CLI contract (stubbed gh, real libs) ---------------------------

make_cli_case() {
  local dir=$1
  mkdir -p "$dir/scripts/lib" "$dir/scripts/workflow" "$dir/.github" "$dir/bin"
  cp "$ROOT/scripts/codex-review-ledger.sh" "$dir/scripts/"
  for lib in gh-api-array.sh codex-request-evidence.sh codex-failure-markers.sh \
             feedback-policy-helpers.sh codex-review-ledger.sh; do
    cp "$ROOT/scripts/lib/$lib" "$dir/scripts/lib/"
  done
  cp "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" "$dir/scripts/workflow/"
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
  repos/o/r/pulls/7)
    # LEDGER_TEST_HEAD_MOVES=1: the second head read sees a new head.
    n=0; [ ! -f "$LEDGER_TEST_DIR/head-reads" ] || n=$(cat "$LEDGER_TEST_DIR/head-reads")
    printf '%s\n' "$((n + 1))" >"$LEDGER_TEST_DIR/head-reads"
    if [ "${LEDGER_TEST_HEAD_MOVES:-0}" = 1 ] && [ "$n" -ge 1 ]; then
      case " $* " in *' --jq '*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;; *) printf '{"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}\n' ;; esac
    else
      case " $* " in *' --jq '*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;; *) printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' ;; esac
    fi ;;
  repos/o/r/issues/7/comments) cat "$LEDGER_TEST_DIR/issue_comments.json" ;;
  repos/o/r/pulls/7/reviews) cat "$LEDGER_TEST_DIR/reviews.json" ;;
  repos/o/r/pulls/7/comments) cat "$LEDGER_TEST_DIR/review_comments.json" ;;
  repos/o/r/issues/7/reactions) cat "$LEDGER_TEST_DIR/issue_reactions.json" ;;
  repos/o/r/issues/comments/*/reactions) printf '[]\n' ;;
  repos/o/r/pulls/comments/*/reactions)
    id=${1#repos/o/r/pulls/comments/}; id=${id%/reactions}
    if [ -f "$LEDGER_TEST_DIR/finding_reactions_$id.json" ]; then cat "$LEDGER_TEST_DIR/finding_reactions_$id.json"; else printf '[]\n'; fi ;;
  # #2553: the PR's commits and timeline, read for failover markers' heads.
  repos/o/r/pulls/7/commits)
    if [ -f "$LEDGER_TEST_DIR/commits.json" ]; then cat "$LEDGER_TEST_DIR/commits.json"; else echo "no commits fixture" >&2; exit 1; fi ;;
  repos/o/r/issues/7/timeline) printf '[]\n' ;;
  # #2591: the GraphQL force-push timeline.
  graphql)
    case "$*" in
      *'object(expression:'*)
        case " $* " in *' owner=o '*' name=r '*) ;; *) echo 'wrong anchor repository' >&2; exit 99 ;; esac
        cat "$LEDGER_TEST_DIR/anchor-resolution.json" ;;
      *) if [ -f "$LEDGER_TEST_DIR/graphql.json" ]; then cat "$LEDGER_TEST_DIR/graphql.json"; else echo "no graphql fixture" >&2; exit 1; fi ;;
    esac ;;
  # #2534: a head-to-head compare, filtered by the caller's --jq like gh does.
  repos/o/r/compare/*)
    [ -f "$LEDGER_TEST_DIR/compare.json" ] || { echo "no compare fixture" >&2; exit 1; }
    filter=.; prev=""
    for a in "$@"; do [ "$prev" != --jq ] || filter=$a; prev=$a; done
    jq -c "$filter" "$LEDGER_TEST_DIR/compare.json" ;;
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
trap 'rm -rf "$WORK" "$TB_DIR"' EXIT

# #2686: run the production CLI, shared parser and real anchor resolver.
# Only GitHub's disambiguation response is stubbed. A first pending request
# makes an accidental anchorless fallback observable as false attribution.
anchor_case() { # directory anchor fields [bot]
  local dir=$1 fields=$2 bot=${3:-chatgpt-codex-connector[bot]}
  make_cli_case "$dir"
  printf 'author_identity: nathanjohnpayne\ncodex:\n  bot_login: "%s"\n' "$bot" >"$dir/policy.yml"
  jq -n --arg bot "$bot" --arg fields "$fields" '
    [{id:101,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-09-25T00:00:00Z"},
     {id:103,user:{login:$bot},created_at:"2026-09-25T00:05:00Z",
      body:("Codex Review: Didn\u0027t find any major issues.\n" + $fields)}]' >"$dir/issue_comments.json"
  printf '%s\n' '{"data":{"repository":{"b0":null,"t0":null,"c0":{"__typename":"Commit","oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}' >"$dir/anchor-resolution.json"
}
D="$WORK/anchor-full"; anchor_case "$D" "Reviewed commit: $HEAD_A" ledger-codex-bot
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e --arg head "$HEAD_A" '.summary.responses == 1 and .responses[0].anchor == $head and .requests[0].outcome == "attributed"' "$D/out" >/dev/null; then
  pass "CLI anchors: a full SHA answers the current pending request"
else
  fail "CLI anchors full: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
D_FULL=$D
D="$WORK/anchor-unique"; anchor_case "$D" 'Reviewed commit: aaaaaaa' ledger-codex-bot
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && cmp -s "$D_FULL/out" "$D/out" && grep -q '^graphql$' "$D/calls"; then
  pass "CLI anchors: a unique abbreviation with the governing bot is equivalent to the full SHA"
else
  fail "CLI anchors unique: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
# #2742: malformed raw fields collapse the parsed tuple to reviewed_shas [],
# the anchorless shape. The default fixture resolves aaaaaaa uniquely, so the
# malformed cases isolate the raw-field check from prefix resolution.
for unresolved in ambiguous absent mixed provider malformed malformed-only; do
  fields='Reviewed commit: aaaaaaa'
  [ "$unresolved" != mixed ] || fields=$(printf 'Reviewed commit: %s\nReviewed commit: aaaaaaa' "$HEAD_A")
  [ "$unresolved" != provider ] || fields=$(printf '%s\nYou have reached your Codex usage limits for code reviews.' "$fields")
  [ "$unresolved" != malformed ] || fields=$(printf 'Reviewed commit: aaaaaaa\nReviewed commit: not-a-sha')
  [ "$unresolved" != malformed-only ] || fields='Reviewed commit: not-a-sha'
  D="$WORK/anchor-$unresolved"; anchor_case "$D" "$fields"
  if [ "$unresolved" = malformed ] || [ "$unresolved" = malformed-only ]; then
    :
  elif [ "$unresolved" = absent ]; then
    printf '%s\n' '{"data":{"repository":{"b0":null,"t0":null,"c0":null}}}' >"$D/anchor-resolution.json"
  else
    printf '%s\n' '{"errors":[{"message":"ambiguous commit prefix","path":["repository","c0"]}],"data":{"repository":{"b0":null,"t0":null,"c0":null}}}' >"$D/anchor-resolution.json"
  fi
  RC=$(run_cli "$D")
  if [ "$RC" = 0 ] && jq -e '.responses == [] and .summary.responses == 0 and .requests[0].outcome == "no_response_yet" and .requests[0].responses == []' "$D/out" >/dev/null; then
    pass "CLI anchors: $unresolved anchor fields cannot answer a pending request or gain head authority"
  else
    fail "CLI anchors $unresolved: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
  fi
done
# #2772 item 1: two different full SHAs in one verdict anchor no single
# commit. The verdict is excluded, so it cannot answer the pending request as
# an anchorless response. Fails open before the fix.
D="$WORK/anchor-conflicting"; anchor_case "$D" "$(printf 'Reviewed commit: %s\nReviewed commit: %s' "$HEAD_A" "$HEAD_B")"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.responses == [] and .summary.responses == 0 and .requests[0].outcome == "no_response_yet"' "$D/out" >/dev/null; then
  pass "CLI anchors: conflicting full-SHA anchor fields cannot answer a pending request"
else
  fail "CLI anchors conflicting: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
# The same SHA twice, in either case, is one anchor and still answers.
D="$WORK/anchor-repeated"; anchor_case "$D" "$(printf 'Reviewed commit: %s\nReviewed commit: %s' "$HEAD_A" "$HEAD_A")"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e --arg head "$HEAD_A" '.summary.responses == 1 and .responses[0].anchor == $head and .requests[0].outcome == "attributed"' "$D/out" >/dev/null; then
  pass "CLI anchors: a repeated identical anchor field is the same single anchor"
else
  fail "CLI anchors repeated: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
# #2772 item 2: prose that mentions reviewed commits is not an anchor field,
# so an anchorless verdict stays an anchorless answer to its request instead
# of being excluded as malformed. Fails closed before the fix.
for prose in 'The reviewed commits look clean.' 'Reviewed commits: all clean.' 'All REVIEWED COMMITS are clean.'; do
  D="$WORK/anchor-prose"; rm -rf "$D"; anchor_case "$D" "$prose"
  RC=$(run_cli "$D")
  if [ "$RC" = 0 ] && jq -e '.summary.responses == 1 and .requests[0].outcome == "attributed"' "$D/out" >/dev/null; then
    pass "CLI anchors: prose '$prose' leaves an anchorless verdict attributable"
  else
    fail "CLI anchors prose '$prose': rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
  fi
done
# Phase 4b P1 on #2859: ordered-list numbering is Markdown decoration too, so a
# numbered malformed field still excludes the verdict. Before the fix such a
# verdict read as an anchorless clean response and could clear a human stop.
for numbered in '1. Reviewed commit: not-a-sha' '2) **Reviewed commit:** `not-a-sha`' '+ Reviewed commit: not-a-sha' \
    '1. - **Reviewed commit:** `not-a-sha`' '1. ### Reviewed commit: not-a-sha' '> 1. * _Reviewed commit_: not-a-sha' \
    'I reviewed commit history and found nothing.'; do
  D="$WORK/anchor-numbered"; rm -rf "$D"; anchor_case "$D" "$numbered"
  RC=$(run_cli "$D")
  if [ "$RC" = 0 ] && jq -e '.responses == [] and .requests[0].outcome == "no_response_yet"' "$D/out" >/dev/null; then
    pass "CLI anchors: a decorated malformed field or bare phrase ('$numbered') still excludes the verdict"
  else
    fail "CLI anchors numbered '$numbered': rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
  fi
done
# Codex P2 on #2859: prose with no "Codex Review:" heading is not a verdict at
# all. Before the heading requirement it entered as an unknown_tier response
# and spent the blocking budget.
D="$WORK/anchor-headless-prose"; anchor_case "$D" ignored
jq '.[1].body = "The reviewed commits look clean."' "$D/issue_comments.json" >"$D/ic.tmp" && mv "$D/ic.tmp" "$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.responses == [] and .summary.responses == 0 and .requests[0].outcome == "no_response_yet"' "$D/out" >/dev/null; then
  pass "CLI anchors: heading-less prose that mentions reviewed commits is no response"
else
  fail "CLI anchors headless prose: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
# A malformed field behind Markdown decoration is still a field.
D="$WORK/anchor-decorated-malformed"; anchor_case "$D" '- **Reviewed commit:** `not-a-sha`'
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.responses == [] and .requests[0].outcome == "no_response_yet"' "$D/out" >/dev/null; then
  pass "CLI anchors: a decorated malformed anchor field still excludes the verdict"
else
  fail "CLI anchors decorated malformed: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
D="$WORK/anchor-error"; anchor_case "$D" 'Reviewed commit: aaaaaaa'
printf 'raise RuntimeError("fixture resolver failure")\n' >"$D/scripts/workflow/resolve-codex-verdict-anchors.py"
RC=$(run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'cannot resolve Codex verdict anchors' "$D/err"; then
  pass "CLI anchors: resolver execution failure exits 3 without a ledger"
else
  fail "CLI anchors error: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
D="$WORK/anchor-legacy"; anchor_case "$D" ''
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.summary.responses == 1 and .responses[0].anchor == null and .requests[0].outcome == "attributed"' "$D/out" >/dev/null; then
  pass "CLI anchors: genuinely anchorless verdicts retain their existing attribution"
else
  fail "CLI anchors legacy: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/ok"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 102, user: {login: "nathanpayne-claude"}, body: "@codex review", created_at: "2026-09-25T00:01:00Z"},
        {id: 103, user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:05:00Z",
         body: "Codex Review: Didn'"'"'t find any major issues.\n**Reviewed commit:** `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.summary.requests == 1 and .summary.foreign_requests == 1
     and ([.requests[] | select(.counted) | .id] == [101]) and .responses[0].class == "clean"
     and ([.requests[].outcome] == ["ambiguous","ambiguous"])' "$D/out" >/dev/null; then
  pass "CLI: counts only the governing author's exact requests; another account's request makes the verdict ambiguous"
else
  fail "CLI ok case: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
if ! grep -q '^repos/o/r/issues/7/reactions$' "$D/calls" && ! grep -qvE '^repos/o/r/(pulls/7|issues/7/comments|pulls/7/reviews|pulls/7/comments|issues/7/reactions|issues/comments/[0-9]+/reactions|pulls/comments/[0-9]+/reactions)$' "$D/calls"; then
  pass "CLI: reads only the PR's own records"
else
  fail "CLI read an unexpected endpoint: $(cat "$D/calls")"
fi

# A CodeRabbit failover request is marked ceiling_exempt from its marker (#2534).
D="$WORK/failover"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 102, user: {login: "nathanjohnpayne"}, created_at: "2026-09-25T00:00:04Z", updated_at: "2026-09-25T00:00:04Z",
         body: "<!-- mergepath-codex-failover:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=101 -->"},
        {id: 103, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T01:00:00Z"}]' >"$D/issue_comments.json"
printf '[]\n' >"$D/commits.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '[.requests[] | select(.counted) | {id, ceiling_exempt}]
     == [{id: 101, ceiling_exempt: true}, {id: 103, ceiling_exempt: false}]' "$D/out" >/dev/null; then
  pass "CLI: a failover-marked request is ceiling_exempt, a deliberate one is not"
else
  fail "CLI failover case: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
# #2553: the marker must name a head this PR had; a foreign head, or an
# unreadable commit list, exempts nothing.
jq -c 'map(if .id == 102 then .body |= sub("head=a{40}"; "head=" + ("1" * 40)) else . end)' "$D/issue_comments.json" >"$D/ic.tmp" && mv "$D/ic.tmp" "$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '[.requests[] | select(.counted) | .ceiling_exempt] == [false, false]' "$D/out" >/dev/null; then
  pass "CLI: a failover marker naming a foreign head exempts nothing"
else
  fail "CLI failover foreign-head case: rc=$RC out=$(jq -c '[.requests[] | {id, ceiling_exempt}]' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
jq -c 'map(if .id == 102 then .body |= sub("head=1{40}"; "head=" + ("b" * 40)) else . end)' "$D/issue_comments.json" >"$D/ic.tmp" && mv "$D/ic.tmp" "$D/issue_comments.json"
printf '[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]\n' >"$D/commits.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '[.requests[] | select(.counted) | .ceiling_exempt] == [true, false]' "$D/out" >/dev/null; then
  pass "CLI: a failover marker naming an earlier PR commit exempts its trigger"
else
  fail "CLI failover earlier-head case: rc=$RC out=$(jq -c '[.requests[] | {id, ceiling_exempt}]' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
# #2591: a head a force-push replaced is only in the GraphQL timeline.
printf '[]\n' >"$D/commits.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '[.requests[] | select(.counted) | .ceiling_exempt] == [false, false]' "$D/out" >/dev/null; then
  pass "CLI: without the GraphQL timeline, a force-pushed-away head exempts nothing"
else
  fail "CLI failover no-graphql case: rc=$RC err=$(cat "$D/err")"
fi
jq -n '{data: {repository: {pullRequest: {timelineItems: {pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{beforeCommit: {oid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}, afterCommit: {oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}}}}}' >"$D/graphql.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '[.requests[] | select(.counted) | .ceiling_exempt] == [true, false]' "$D/out" >/dev/null; then
  pass "CLI: a failover marker on a head a force-push replaced exempts its trigger"
else
  fail "CLI failover force-pushed case: rc=$RC out=$(jq -c '[.requests[] | {id, ceiling_exempt}]' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
rm -f "$D/commits.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '[.requests[] | select(.counted) | .ceiling_exempt] == [false, false]' "$D/out" >/dev/null; then
  pass "CLI: an unreadable commit list exempts nothing"
else
  fail "CLI failover unreadable-commits case: rc=$RC err=$(cat "$D/err")"
fi

# Fixed-finding evidence (#2534): a non-bot thumbs-up on a Codex root is a fix
# disposition unless the thread is tagged, the root also has a thumbs-down, or
# only the bot reacted; the CLI then compares the reviewed head with each later
# reviewed head.
fx_case() { # <dir> <reactions-60-json> <extra-review-comments-json> [root-60-rollup-json]
  make_cli_case "$1"
  jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
          {id: 102, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T01:00:00Z"}]' >"$1/issue_comments.json"
  jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:10:00Z", commit_id: "cccccccccccccccccccccccccccccccccccccccc", body: ""},
          {id: 51, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T01:10:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""}]' >"$1/reviews.json"
  jq -n --argjson extra "$3" --argjson rollup "${4:-null}" '[({id: 60, pull_request_review_id: 50, in_reply_to_id: null, path: "x.sh", user: {login: "chatgpt-codex-connector[bot]"},
           body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** first", created_at: "2026-09-25T00:10:00Z"}
           + (if $rollup == null then {} else {reactions: $rollup} end)),
          {id: 70, pull_request_review_id: 51, in_reply_to_id: null, path: "y.sh", user: {login: "chatgpt-codex-connector[bot]"},
           body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** second", created_at: "2026-09-25T01:10:00Z"}] + $extra' >"$1/review_comments.json"
  printf '%s\n' "$2" >"$1/finding_reactions_60.json"
  jq -n '{status: "ahead", files: [{filename: "x2.sh", previous_filename: "x.sh"}, {filename: "z.sh"}]}' >"$1/compare.json"
}
UP='[{"content": "+1", "user": {"login": "nathanpayne-claude"}, "created_at": "2026-09-25T00:30:00Z"}]'
D="$WORK/fixes"; fx_case "$D" "$UP" '[]'
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.fixes == [60]
     and .head_changes == [{base: "cccccccccccccccccccccccccccccccccccccccc", head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                            status: "ahead", files: ["x.sh", "x2.sh", "z.sh"]}]
     and ([.responses[] | select(.window == 1) | .blocking_findings] == [[{id: 60, path: "x.sh"}]])' "$D/out" >/dev/null; then
  pass "CLI: a non-bot thumbs-up is a fix disposition, and the reviewed head is compared with the later one"
else
  fail "CLI fixes case: rc=$RC out=$(jq -c '{fixes, head_changes, r: [.responses[] | {rid, blocking_findings}]}' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
grep -q '^repos/o/r/compare/cccccccccccccccccccccccccccccccccccccccc\.\.\.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$' "$D/calls" \
  && pass "CLI: the compare reads the reviewed head against the later reviewed head" \
  || fail "CLI: unexpected compare calls: $(grep compare "$D/calls")"
for _fx in "tag|$UP|[{\"id\": 61, \"pull_request_review_id\": 52, \"in_reply_to_id\": 60, \"path\": \"x.sh\", \"user\": {\"login\": \"nathanjohnpayne\"}, \"body\": \"[mergepath-resolve: deferred-to-followup] later\", \"created_at\": \"2026-09-25T00:40:00Z\"}]" \
           "down|[{\"content\": \"+1\", \"user\": {\"login\": \"nathanpayne-claude\"}, \"created_at\": \"2026-09-25T00:30:00Z\"}, {\"content\": \"-1\", \"user\": {\"login\": \"nathanpayne-codex\"}, \"created_at\": \"2026-09-25T00:31:00Z\"}]|[]" \
           "bot|[{\"content\": \"+1\", \"user\": {\"login\": \"chatgpt-codex-connector[bot]\"}, \"created_at\": \"2026-09-25T00:30:00Z\"}]|[]"; do
  _name=${_fx%%|*}; _rest=${_fx#*|}; _react=${_rest%|*}; _extra=${_rest##*|}
  D="$WORK/fixes-$_name"; fx_case "$D" "$_react" "$_extra"
  RC=$(run_cli "$D")
  if [ "$RC" = 0 ] && jq -e '.fixes == [] and .head_changes == []' "$D/out" >/dev/null; then
    pass "CLI: $_name is no fix disposition and reads no compare"
  else
    fail "CLI fixes-$_name case: rc=$RC out=$(jq -c '{fixes, head_changes}' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
  fi
done
# A discretionary finding cannot make a runaway, so the fix pass does not read
# its reactions (the rebuttal pass still reads them once).
D="$WORK/fixes-p2"; fx_case "$D" "$UP" '[]'
jq -c 'map(if .id == 60 then .body = "**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>** minor" else . end)' \
  "$D/review_comments.json" >"$D/rc.tmp" && mv "$D/rc.tmp" "$D/review_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.fixes == []' "$D/out" >/dev/null \
   && [ "$(grep -c '^repos/o/r/pulls/comments/60/reactions$' "$D/calls")" = 1 ]; then
  pass "CLI: a discretionary finding is not read for a fix disposition"
else
  fail "CLI fixes-p2 case: rc=$RC fixes=$(jq -c .fixes "$D/out" 2>/dev/null) calls=$(grep reactions "$D/calls" | tr '\n' ' ')"
fi
# resolve-pr-threads.sh records a fix as addressed-elsewhere: that tag keeps
# the disposition; another tag beside it still removes it.
AE='[{"id": 61, "pull_request_review_id": 52, "in_reply_to_id": 60, "path": "x.sh", "user": {"login": "nathanjohnpayne"}, "body": "[mergepath-resolve: addressed-elsewhere] fixed in abc1234", "created_at": "2026-09-25T00:40:00Z"}]'
D="$WORK/fixes-addressed"; fx_case "$D" "$UP" "$AE"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.fixes == [60]' "$D/out" >/dev/null; then
  pass "CLI: an addressed-elsewhere tag is the fix class and keeps the disposition"
else
  fail "CLI fixes-addressed case: rc=$RC out=$(jq -c '{fixes}' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
D="$WORK/fixes-addressed-nitpick"
fx_case "$D" "$UP" "$(printf '%s' "$AE" | jq -c '. + [{id: 62, pull_request_review_id: 53, in_reply_to_id: 60, path: "x.sh", user: {login: "nathanjohnpayne"}, body: "[mergepath-resolve: nitpick-noted] later", created_at: "2026-09-25T00:41:00Z"}]')"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.fixes == []' "$D/out" >/dev/null; then
  pass "CLI: a nitpick tag beside addressed-elsewhere removes the disposition"
else
  fail "CLI fixes-addressed-nitpick case: rc=$RC out=$(jq -c '{fixes}' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
# A thumbs-down the rollup has not caught up with is not read as a rebuttal,
# but the fix read still sees it.
D="$WORK/fixes-stale-down"
fx_case "$D" '[{"content": "+1", "user": {"login": "nathanpayne-claude"}, "created_at": "2026-09-25T00:30:00Z"}, {"content": "-1", "user": {"login": "nathanpayne-codex"}, "created_at": "2026-09-25T00:31:00Z"}]' '[]' '{"+1": 1, "-1": 0}'
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.fixes == [] and .rebuttals == []' "$D/out" >/dev/null; then
  pass "CLI: a thumbs-down behind a stale rollup still blocks the fix disposition"
else
  fail "CLI fixes-stale-down case: rc=$RC out=$(jq -c '{fixes, rebuttals}' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi
# A compare that fails records the pair without files, so nothing is fixed.
D="$WORK/fixes-unreadable"; fx_case "$D" "$UP" '[]'; rm -f "$D/compare.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.fixes == [60] and .head_changes[0].status == "unreadable" and .head_changes[0].files == []' "$D/out" >/dev/null; then
  pass "CLI: an unreadable compare records no changed files"
else
  fail "CLI fixes-unreadable case: rc=$RC out=$(jq -c '{fixes, head_changes}' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi

# --expect-head (#1560 slice 3): the requester's blocking-review count must be
# taken at the head it is about to request a review of.
D="$WORK/expect-head"; make_cli_case "$D"
printf '[]\n' >"$D/issue_comments.json"
RC=$(run_cli "$D" --expect-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
if [ "$RC" = 0 ] && jq -e '.head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$D/out" >/dev/null; then
  pass "CLI: --expect-head matching the PR head prints the ledger"
else
  fail "CLI expect-head match: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
RC=$(run_cli "$D" --expect-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'not the expected' "$D/err"; then
  pass "CLI: --expect-head naming another head fails closed (exit 3, nothing printed)"
else
  fail "CLI expect-head mismatch: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
rm -f "$D/head-reads"
RC=$(LEDGER_TEST_HEAD_MOVES=1 run_cli "$D" --expect-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'head moved' "$D/err"; then
  pass "CLI: a head that moves during the evidence reads fails closed (#1576 round 6)"
else
  fail "CLI head moved mid-read: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi
RC=$(run_cli "$D" --expect-head not-a-sha)
if [ "$RC" = 2 ] && [ ! -s "$D/out" ]; then
  pass "CLI: --expect-head with a malformed sha is a usage error"
else
  fail "CLI expect-head malformed: rc=$RC out=$(cat "$D/out")"
fi

# The ledger reports the blocking-review budget of the policy snapshot it read
# (#1576 round 5): absent is 10, a valid value is a number, an invalid one null.
for _mb in absent 3 false; do
  D="$WORK/maxblocking-$_mb"; make_cli_case "$D"
  printf '[]\n' >"$D/issue_comments.json"
  [ "$_mb" = absent ] || printf '  max_blocking_reviews: %s\n' "$_mb" >>"$D/policy.yml"
  case "$_mb" in absent) _want=10 ;; 3) _want=3 ;; *) _want=null ;; esac
  RC=$(run_cli "$D")
  if [ "$RC" = 0 ] && [ "$(jq -c '.max_blocking_reviews' "$D/out")" = "$_want" ]; then
    pass "CLI: a governing max_blocking_reviews of $_mb is reported as $_want"
  else
    fail "CLI max_blocking_reviews $_mb: rc=$RC got=$(jq -c '.max_blocking_reviews' "$D/out" 2>/dev/null) err=$(cat "$D/err")"
  fi
done

# --expect-policy (#1576): one policy snapshot for the caller and the ledger.
# The fingerprint ignores key order and formatting, and changes with content.
(
  . "$ROOT/scripts/lib/codex-request-evidence.sh"
  fp1=$(crqe_policy_fingerprint '{"a":1,"codex":{"bot_login":"x","max_review_rounds":3}}')
  fp2=$(crqe_policy_fingerprint '{"codex":{"max_review_rounds":3,"bot_login":"x"},  "a":1}')
  fp3=$(crqe_policy_fingerprint '{"a":1,"codex":{"bot_login":"y","max_review_rounds":3}}')
  [ -n "$fp1" ] && [ "$fp1" = "$fp2" ] && [ "$fp1" != "$fp3" ] && ! crqe_policy_fingerprint 'not json' >/dev/null
) && pass "fingerprint: stable across key order, different for different content, fails on malformed input" \
  || fail "fingerprint: crqe_policy_fingerprint is not a stable content identity"
D="$WORK/expect-policy"; make_cli_case "$D"
printf '[]\n' >"$D/issue_comments.json"
RC=$(run_cli "$D")
_fp=$(jq -r '.policy_fingerprint // empty' "$D/out" 2>/dev/null)
RC2=$(run_cli "$D" --expect-policy "$_fp")
_out2=$(cat "$D/out")
RC3=$(run_cli "$D" --expect-policy 1-1)
if [ "$RC" = 0 ] && [[ "$_fp" =~ ^[0-9]+-[0-9]+$ ]] && [ "$RC2" = 0 ] \
   && [ "$(printf '%s' "$_out2" | jq -r .policy_fingerprint)" = "$_fp" ] \
   && [ "$RC3" = 3 ] && [ ! -s "$D/out" ] && grep -q 'policy changed' "$D/err"; then
  pass "CLI: --expect-policy accepts its own snapshot's fingerprint and refuses another (exit 3, nothing printed)"
else
  fail "CLI expect-policy: rc=$RC/$RC2/$RC3 fp=$_fp err=$(cat "$D/err")"
fi

# A non-string governing bot login is malformed, never coerced (#1576 round 4).
for _bot in 42 '["chatgpt-codex-connector[bot]"]' '{x: 1}' codex-false; do
  D="$WORK/bot-$RANDOM"; make_cli_case "$D"
  printf '[]\n' >"$D/issue_comments.json"
  printf 'author_identity: nathanjohnpayne\ncodex:\n  bot_login: %s\n' "$_bot" >"$D/policy.yml"
  # A boolean codex block is malformed too, not an empty one (CodeRabbit on #1576).
  [ "$_bot" != codex-false ] || printf 'author_identity: nathanjohnpayne\ncodex: false\n' >"$D/policy.yml"
  RC=$(run_cli "$D")
  if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'bot_login is malformed' "$D/err"; then
    pass "CLI: a governing bot_login of $_bot fails closed"
  else
    fail "CLI bot_login $_bot: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
  fi
done

# A Codex review with no submitted_at cannot be windowed (#1576 round 10).
D="$WORK/no-submitted-at"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: null, commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""}]' >"$D/reviews.json"
RC=$(run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'no submitted_at' "$D/err"; then
  pass "CLI: a Codex review with no submitted_at fails closed"
else
  fail "CLI null submitted_at: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

# A present malformed instant reaches the pure library; its refusal must keep
# the CLI error boundary (exit 3, no partial JSON or summary output).
D="$WORK/bad-submitted-at"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "!", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: "P1: blocking"}]' >"$D/reviews.json"
for _mode in json summary; do
  _args=(); [ "$_mode" != summary ] || _args+=(--summary)
  RC=$(run_cli "$D" "${_args[@]}")
  if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'ledger computation failed' "$D/err"; then
    pass "CLI: malformed submitted_at refuses $_mode output"
  else
    fail "CLI malformed submitted_at ($_mode): rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
  fi
done

# Rebuttal collection (#1560 slice 3): a tagged thread, and a thumbs-down on
# the root, are rebuttals; the bot's own thumbs-down and a rollup that rules
# one out are not read as one.
D="$WORK/rebuttals"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:10:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""}]' >"$D/reviews.json"
jq -n '[{id: 60, pull_request_review_id: 50, in_reply_to_id: null, path: "x.sh", user: {login: "chatgpt-codex-connector[bot]"}, body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** thing", created_at: "2026-09-25T00:10:00Z", reactions: {"-1": 0}},
        {id: 61, pull_request_review_id: 51, in_reply_to_id: 60, path: "x.sh", user: {login: "nathanjohnpayne"}, body: "This does not apply because the caller already validates it.", created_at: "2026-09-25T00:20:00Z"},
        {id: 62, pull_request_review_id: 52, in_reply_to_id: 60, path: "x.sh", user: {login: "nathanjohnpayne"}, body: "[mergepath-resolve: rebuttal-recorded] rebutted", created_at: "2026-09-25T00:40:00Z"},
        {id: 70, pull_request_review_id: 50, in_reply_to_id: null, path: "y.sh", user: {login: "chatgpt-codex-connector[bot]"}, body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** other", created_at: "2026-09-25T00:10:00Z", reactions: {"-1": 2}},
        {id: 71, pull_request_review_id: 53, in_reply_to_id: 70, path: "y.sh", user: {login: "nathanjohnpayne"}, body: "[mergepath-resolve: rebuttal-recorded] rebutted", created_at: "2026-09-25T00:50:00Z"},
        {id: 80, pull_request_review_id: 50, in_reply_to_id: null, path: "z.sh", user: {login: "chatgpt-codex-connector[bot]"}, body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** third", created_at: "2026-09-25T00:10:00Z", reactions: {"-1": 1}}]' >"$D/review_comments.json"
jq -n '[{content: "-1", user: {login: "nathanpayne-claude"}, created_at: "2026-09-25T00:30:00Z"},
        {content: "-1", user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:15:00Z"}]' >"$D/finding_reactions_70.json"
jq -n '[{content: "-1", user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-09-25T00:15:00Z"}]' >"$D/finding_reactions_80.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '
     (.rebuttals | map({finding, path, at, sources})) == [
       {finding: 60, path: "x.sh", at: "2026-09-25T00:40:00Z", sources: ["tag"]},
       {finding: 70, path: "y.sh", at: "2026-09-25T00:50:00Z", sources: ["tag", "thumbs-down"]}]
     and (.responses[0].blocking_paths == ["x.sh", "y.sh", "z.sh"])' "$D/out" >/dev/null \
   && ! grep -q 'pulls/comments/60/reactions' "$D/calls"; then
  pass "CLI: a tagged thread and a reviewer thumbs-down are rebuttals, dated by the rebuttal evidence itself (not earlier replies); the bot's own thumbs-down is not"
else
  fail "CLI rebuttals: rc=$RC out=$(jq -c '{rebuttals, paths: [.responses[].blocking_paths]}' "$D/out" 2>/dev/null) calls=$(tr '\n' ' ' <"$D/calls") err=$(cat "$D/err")"
fi
# A reply edited to carry the tag dates from its edit, not its creation (#1579
# Phase 4b): otherwise a Codex review between the two would read as testing it.
jq '(.[] | select(.id == 62)) |= (.created_at = "2026-09-25T00:12:00Z" | .updated_at = "2026-09-25T00:45:00Z")' \
  "$D/review_comments.json" >"$D/rc.tmp" && mv "$D/rc.tmp" "$D/review_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.rebuttals | map(select(.finding == 60)) | .[0].at == "2026-09-25T00:45:00Z"' "$D/out" >/dev/null; then
  pass "CLI: a reply edited to carry the rebuttal tag is dated from its edit"
else
  fail "CLI edited tag reply: rc=$RC rebuttals=$(jq -c .rebuttals "$D/out" 2>/dev/null)"
fi
RC=$(LEDGER_TEST_FAIL_ENDPOINT=repos/o/r/pulls/comments/70/reactions run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ]; then
  pass "CLI: a failed thumbs-down read fails closed"
else
  fail "CLI rebuttal read failure: rc=$RC"
fi

# Review-body rebuttals (#1560 canary, finding 2): an author ack of a Codex
# review with a blocking BODY finding is a path-null rebuttal, dated by the
# ack's edit; an ack of a non-blocking body, or by the bot, is not.
D="$WORK/body-rebuttal"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 102, user: {login: "nathanpayne-claude"}, body: "[mergepath-review-ack: 50 0123456789ab]\n\nDeclined: not applicable.", created_at: "2026-09-25T00:20:00Z", updated_at: "2026-09-25T00:25:00Z"},
        {id: 103, user: {login: "nathanpayne-claude"}, body: "[mergepath-review-ack: 51 0123456789ab]", created_at: "2026-09-25T00:30:00Z"},
        {id: 104, user: {login: "chatgpt-codex-connector[bot]"}, body: "[mergepath-review-ack: 50 0123456789ab]", created_at: "2026-09-25T00:40:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:10:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** body finding"},
        {id: 51, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:11:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         body: "**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>** minor body finding"}]' >"$D/reviews.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.rebuttals == [{finding: 50, path: null, at: "2026-09-25T00:25:00Z", sources: ["review-ack"]}]' "$D/out" >/dev/null; then
  pass "CLI: an ack of a blocking review-body finding is a path-null rebuttal; non-blocking and bot acks are not"
else
  fail "CLI body rebuttal: rc=$RC rebuttals=$(jq -c .rebuttals "$D/out" 2>/dev/null) err=$(cat "$D/err")"
fi

# A malformed reaction rollup fails closed instead of reading as "no thumbs-down"
# (#1582), including a present false or null, which `// {}` used to default (#1584).
for _rollup in '"x"' false null; do
  D="$WORK/bad-rollup-$_rollup"; make_cli_case "$D"
  jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
  jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:10:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""}]' >"$D/reviews.json"
  jq -n --argjson r "$_rollup" '[{id: 60, pull_request_review_id: 50, in_reply_to_id: null, path: "x.sh", user: {login: "chatgpt-codex-connector[bot]"}, body: "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>** thing", created_at: "2026-09-25T00:10:00Z", reactions: $r}]' >"$D/review_comments.json"
  RC=$(run_cli "$D")
  if [ "$RC" = 3 ] && [ ! -s "$D/out" ]; then
    pass "CLI: a malformed reaction rollup ($_rollup) fails closed (#1582)"
  else
    fail "CLI malformed rollup $_rollup: rc=$RC out=$(head -c 200 "$D/out")"
  fi
done

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
         body: "Codex Review: No major issues.\n**Reviewed commit:** `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.bot == "chatgpt-codex-connector[bot]" and .summary.responses == 1' "$D/out" >/dev/null; then
  pass "CLI: an empty codex.bot_login falls back to the default bot, as the gate does"
else
  fail "CLI empty bot_login: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

# A busy PR's comment history is larger than the OS argument limit; it must
# reach jq through files, not argv (8 PRs failed this way in calibration).
D="$WORK/botquote"; make_cli_case "$D"
jq -n '[{id: 101, user: {login: "nathanjohnpayne", type: "User"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"},
        {id: 102, user: {login: "coderabbitai[bot]", type: "Bot"}, body: "> @codex review\nQuoted for context.", created_at: "2026-09-25T00:01:00Z"},
        {id: 103, user: {login: "chatgpt-codex-connector[bot]", type: "Bot"}, created_at: "2026-09-25T00:05:00Z",
         body: "Codex Review: No major issues.\n**Reviewed commit:** `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`"}]' >"$D/issue_comments.json"
RC=$(run_cli "$D" --summary)
if [ "$RC" = 0 ] && grep -q '^requests: 1 counted, 0 foreign' "$D/out" && grep -q '^counted outcomes: attributed 1,' "$D/out" \
   && grep -q '^foreign outcomes: attributed 0, ambiguous 0' "$D/out"; then
  pass "CLI: a bot quoting a request is not a requester; --summary prints foreign outcomes"
else
  fail "CLI bot quote: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/large"; make_cli_case "$D"
jq -n --arg pad "$(head -c 4000 /dev/zero | tr '\0' 'x')" '
  [{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]
  + [range(1; 600) | {id: (1000 + .), user: {login: "someone"}, body: ("note " + $pad), created_at: "2026-09-25T00:01:00Z"}]' \
  >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && [ "$(wc -c <"$D/issue_comments.json")" -gt 2000000 ] && jq -e '.summary.requests == 1' "$D/out" >/dev/null; then
  pass "CLI: a comment history larger than the argument limit is read through files"
else
  fail "CLI large input: rc=$RC size=$(wc -c <"$D/issue_comments.json") err=$(tail -2 "$D/err")"
fi

D="$WORK/flowpolicy"; make_cli_case "$D"
printf '%s\n' 'author_identity: nathanjohnpayne' 'feedback_policy: {mode: address-all}' >"$D/policy.yml"
printf '[]\n' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'refusing to guess' "$D/err"; then
  pass "CLI: a feedback_policy the shared tier reader cannot read fails closed"
else
  fail "CLI flow-style policy: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

# #1574: values the shared reader ignores must not pass the cross-check.
for bad in 'feedback_policy: {mode: typo}' 'feedback_policy: {priorities: {p1: requird}}' \
           'feedback_policy: {mode: by-priority, priorities: [p1]}' 'feedback_policy: {mode: 3}'; do
  D="$WORK/badpolicy-$(printf '%s' "$bad" | cksum | cut -d' ' -f1)"; make_cli_case "$D"
  printf '%s\n' 'author_identity: nathanjohnpayne' "$bad" >"$D/policy.yml"
  printf '[]\n' >"$D/issue_comments.json"
  RC=$(run_cli "$D")
  if [ "$RC" = 3 ] && [ ! -s "$D/out" ] && grep -q 'feedback_policy' "$D/err"; then
    pass "#1574: an invalid feedback_policy value fails closed ($bad)"
  else
    fail "#1574 invalid policy ($bad): rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
  fi
done

D="$WORK/emptypriority"; make_cli_case "$D"
printf '%s\n' 'author_identity: nathanjohnpayne' 'feedback_policy:' '  mode: by-priority' '  priorities:' '    p0: required' '    p1:' >"$D/policy.yml"
printf '[]\n' >"$D/issue_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '.required_tiers == ["p0"]' "$D/out" >/dev/null; then
  pass "an empty priority value means unset, as in the shared reader"
else
  fail "empty priority: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
fi

D="$WORK/blockpolicy"; make_cli_case "$D"
printf '%s\n' 'author_identity: nathanjohnpayne' 'feedback_policy:' '  mode: address-all' >"$D/policy.yml"
jq -n '[{id: 101, user: {login: "nathanjohnpayne"}, body: "@codex review", created_at: "2026-09-25T00:00:00Z"}]' >"$D/issue_comments.json"
jq -n '[{id: 50, user: {login: "chatgpt-codex-connector[bot]"}, submitted_at: "2026-09-25T00:05:00Z", commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", body: ""}]' >"$D/reviews.json"
jq -n '[{id: 60, user: {login: "chatgpt-codex-connector[bot]"}, pull_request_review_id: 50, in_reply_to_id: null, body: "![P2 Badge] minor", created_at: "2026-09-25T00:05:00Z"}]' >"$D/review_comments.json"
RC=$(run_cli "$D")
if [ "$RC" = 0 ] && jq -e '(.required_tiers | index("p2") != null) and .responses[0].class == "blocking"' "$D/out" >/dev/null; then
  pass "CLI: a block-style address-all policy makes a P2 blocking"
else
  fail "CLI block-style policy: rc=$RC out=$(cat "$D/out") err=$(cat "$D/err")"
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

for expr in 'scan("reviewed commit[^0-9a-z_\\r\\n]{0,6}([^\\r\\n]*)")' \
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
