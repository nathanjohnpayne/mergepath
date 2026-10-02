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
# A reaction-only clean pass has no anchor, so after the first window its
# attribution is ambiguous: it may be a late answer to the earlier request.
# Ambiguity never clears the stop (#1579).
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" '[]' "$(reaction 900 2026-09-25T02:10:00Z | arr)" '[]')
stop_check "stops: an ambiguously attributed clean pass leaves the rebuttal untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
# A response that lands after the rebuttal but answers a request posted before
# it cannot have read the rebuttal (#1579): the only request predates it.
IN=$(inputs "$(req 1 2026-09-25T00:00:00Z | arr)" "$(printf '%s\n' "$FIRST" "$(preview 11 2026-09-25T01:30:00Z '[]')" | arr)" '[]' '[]' '[]')
stop_check "stops: a response to a request already in flight before the rebuttal leaves it untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
# A provider-block notice after the rebuttal is not Codex re-reading it (#1579).
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" '[]' '[]' "$(block 901 2026-09-25T02:10:00Z usage_limit | arr)")
stop_check "stops: a provider-block notice after a rebuttal leaves it untested" "$(stops "$IN" "$RB" 10)" '.stops == ["untested-rebuttal"]'
# A response in the same second as the rebuttal cannot be shown to have read
# it, so the rebuttal stays untested.
IN=$(inputs "$R2" "$(printf '%s\n' "$FIRST" | arr)" '[]' "$(reaction 900 2026-09-25T02:10:00Z | arr)" '[]')
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
if ! grep -qvE '^repos/o/r/(pulls/7|issues/7/comments|pulls/7/reviews|pulls/7/comments|issues/7/reactions|issues/comments/[0-9]+/reactions|pulls/comments/[0-9]+/reactions)$' "$D/calls"; then
  pass "CLI: reads only the PR's own records"
else
  fail "CLI read an unexpected endpoint: $(cat "$D/calls")"
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
         body: "Codex Review: No major issues.\n**Reviewed commit:** `aaaaaaa`"}]' >"$D/issue_comments.json"
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
         body: "Codex Review: No major issues.\n**Reviewed commit:** `aaaaaaa`"}]' >"$D/issue_comments.json"
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
