#!/usr/bin/env bash
# tests/test_stalled_pr_resume.sh
#
# Fixture-driven regression suite for the stalled pull-request finder
# (scripts/workflow/stalled-prs.sh) and the resume entry point
# (scripts/workflow/resume-stalled-pr.sh) — nathanjohnpayne/mergepath#2165.
#
# Part 1 replays a synthetic stalled-prs/v1 snapshot through --input and
# asserts the classification of every class the finder defines (stalled in
# each of its reasons, live, waiting-on-ci, waiting-on-bot, waiting-on-human)
# plus the next-action derivation, NBSP tolerance in a Codex verdict, the
# markup-tolerant trigger match, draft exclusion and the exit-code contract.
#
# Part 2 runs the live fetch path against a PATH-shimmed `gh` that serves
# canned REST/GraphQL responses, with stub gate and requester scripts, and
# asserts the normalization, the pagination discipline, the gate delegation
# and the resume script's --execute hand-off. Hermetic: no token, no network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINDER="$ROOT/scripts/workflow/stalled-prs.sh"
RESUME="$ROOT/scripts/workflow/resume-stalled-pr.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stalled-pr-resume.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

for subject in "$FINDER" "$RESUME"; do
  if [ ! -x "$subject" ]; then
    echo "FAIL: missing executable $subject" >&2
    exit 1
  fi
done
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

NOW="2026-10-13T12:00:00Z"
REPO="octo/demo"
AUTHOR="nathanjohnpayne"
CODEX="chatgpt-codex-connector[bot]"
RABBIT="coderabbitai[bot]"
sha() { printf '%040d' "$1"; }

# pr <number> <head-pushed-at> <ci-state> [jq override] [--argjson name value ...]
# The override is a jq expression applied to the base record; the trailing
# arguments are passed to jq verbatim so an override can splice in records
# built by the helpers below (`.reviews = [$rev]`).
pr() {
  local number="$1" pushed="$2" ci="$3" overrides="${4:-.}"
  shift 3; [ "$#" -eq 0 ] || shift
  jq -cn --argjson n "$number" --arg pushed "$pushed" --arg ci "$ci" --arg head "$(sha "$number")" --arg author "$AUTHOR" "$@" '
    {number: $n, title: ("PR " + ($n|tostring)), url: ("https://github.com/octo/demo/pull/" + ($n|tostring)),
     author: $author, draft: false, head_sha: $head, head_ref: ("feat/" + ($n|tostring)), labels: [],
     head_repo: "octo/demo", fork: false, head_pushed_at: $pushed, head_pushed_at_source: "check-run",
     merge_gate_check: "absent", ci_state: $ci, reviews: [], issue_comments: [], review_comments: [], gate: null}
    | '"$overrides"
}
review() { # <id> <login> <state> <at> <commit> [body]
  # A real review round carries a body (Codex: "### 💡 Codex Review", CodeRabbit:
  # "Actionable comments posted: N"); only the wrapper GitHub emits around a
  # bot's inline reply is body-less, and a test passes "" for that shape.
  jq -cn --argjson id "$1" --arg login "$2" --arg state "$3" --arg at "$4" --arg commit "$5" --arg body "${6-review round body}" \
    '{id: $id, state: $state, submitted_at: $at, commit_id: $commit, body: $body, user: {login: $login, type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)}}'
}
comment() { # <id> <login> <at> <body> [updated_at]
  jq -cn --argjson id "$1" --arg login "$2" --arg at "$3" --arg body "$4" --arg updated "${5:-$3}" \
    '{id: $id, created_at: $at, updated_at: $updated, body: $body, user: {login: $login, type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)}}'
}
inline() { # <id> <login> <at> <commit> <in_reply_to|null> [updated_at]
  jq -cn --argjson id "$1" --arg login "$2" --arg at "$3" --arg commit "$4" --argjson reply "$5" --arg updated "${6:-$3}" \
    '{id: $id, created_at: $at, updated_at: $updated, commit_id: $commit, original_commit_id: $commit, in_reply_to_id: $reply,
      html_url: ("https://github.com/octo/demo/pull/1#discussion_r" + ($id|tostring)), body: "finding",
      user: {login: $login, type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)}}'
}

SUMMARY_RUNNING=$'<!-- codex-pull-request-review-summary -->\n| | Status | Commit | Trigger |\n|---|---|---|---|\n| 📝 **Code Review** | **Running** | `'"$(sha 113 | cut -c1-7)"'` | @codex review |'
NBSP=$'\xc2\xa0'
NBSP_VERDICT="Codex Review: Didn't find any major issues.${NBSP}Reviewed${NBSP}commit:${NBSP}$(sha 110)"

{
  # 101: Codex findings round 10h ago, two findings, nothing after → stalled / push fix
  pr 101 "2026-10-13T01:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f1, $f2]' \
    --argjson rev "$(review 1 "$CODEX" COMMENTED "2026-10-13T01:45:00Z" "$(sha 101)")" \
    --argjson f1 "$(inline 1 "$CODEX" "2026-10-13T01:45:00Z" "$(sha 101)" null)" \
    --argjson f2 "$(inline 2 "$CODEX" "2026-10-13T01:45:00Z" "$(sha 101)" null)"
  # 116: same round, the agent replied to one finding and vanished → stalled (idle) / push fix
  pr 116 "2026-10-13T01:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f1, $f2, $r2]' \
    --argjson rev "$(review 6 "$CODEX" COMMENTED "2026-10-13T01:45:00Z" "$(sha 116)")" \
    --argjson f1 "$(inline 6 "$CODEX" "2026-10-13T01:45:00Z" "$(sha 116)" null)" \
    --argjson f2 "$(inline 7 "$CODEX" "2026-10-13T01:45:00Z" "$(sha 116)" null)" \
    --argjson r2 "$(inline 8 "$AUTHOR" "2026-10-13T01:50:00Z" "$(sha 116)" 7)"
  # 102: same shape, verdict 30 minutes ago → live
  pr 102 "2026-10-13T11:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f1]' \
    --argjson rev "$(review 2 "$CODEX" COMMENTED "2026-10-13T11:30:00Z" "$(sha 102)")" \
    --argjson f1 "$(inline 5 "$CODEX" "2026-10-13T11:30:00Z" "$(sha 102)" null)"
  # 103: fresh push, checks pending → waiting-on-ci
  pr 103 "2026-10-13T11:50:00Z" PENDING
  # 104: push, CI green, backticked @codex review 35 minutes ago → waiting-on-bot
  pr 104 "2026-10-13T11:20:00Z" SUCCESS '.issue_comments = [$c]' \
    --argjson c "$(comment 10 "$AUTHOR" "2026-10-13T11:25:00Z" 'Requesting: `@codex review`')"
  # 105: reviewer approval 5h ago, CI green, gate passes → stalled / merge
  pr 105 "2026-10-13T06:00:00Z" SUCCESS '.reviews = [$rev] | .gate = {exit: 0, reason: ""}' \
    --argjson rev "$(review 3 "nathanpayne-claude" APPROVED "2026-10-13T07:00:00Z" "$(sha 105)")"
  # 106: push 4h ago, CI green, nobody requested a review → stalled / request codex
  pr 106 "2026-10-13T08:00:00Z" SUCCESS
  # 107: Phase 4b handoff posted after the verdict → waiting-on-human
  pr 107 "2026-10-13T06:00:00Z" SUCCESS '.reviews = [$rev] | .issue_comments = [$c]' \
    --argjson rev "$(review 4 "$CODEX" COMMENTED "2026-10-13T07:00:00Z" "$(sha 107)")" \
    --argjson c "$(comment 11 "nathanpayne-claude" "2026-10-13T08:00:00Z" $'## External Review Required\n\n**PR:** #107')"
  # 108: human-hold label → waiting-on-human regardless of age
  pr 108 "2026-10-13T06:00:00Z" SUCCESS '.labels = ["size:M", "human-hold"]'
  # 109: draft → excluded from the report
  pr 109 "2026-10-13T01:00:00Z" SUCCESS '.draft = true'
  # 110: NBSP-laden affirmative Codex verdict naming the head; gate fails on (b) → stalled / investigate
  pr 110 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$c] | .gate = {exit: 1, reason: "gate (b): no APPROVED review from an available reviewer"}' \
    --argjson c "$(comment 12 "$CODEX" "2026-10-13T06:00:00Z" "$NBSP_VERDICT")"
  # 111: @codex review posted 7h ago, never answered → stalled / request codex (machine wait outlived)
  pr 111 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$c]' \
    --argjson c "$(comment 13 "$AUTHOR" "2026-10-13T05:10:00Z" '@codex review')"
  # 112: push 6h ago, CI red → stalled / push fix
  pr 112 "2026-10-13T06:00:00Z" FAILURE
  # 113: Codex Review Summary reports the head Running → waiting-on-bot
  pr 113 "2026-10-13T11:30:00Z" SUCCESS '.issue_comments = [$c]' \
    --argjson c "$(comment 14 "$CODEX" "2026-10-13T11:31:00Z" "$SUMMARY_RUNNING" "2026-10-13T11:32:00Z")"
  # 114: CHANGES_REQUESTED by a reviewer identity 5h ago, no inline findings → stalled / push fix
  pr 114 "2026-10-13T06:00:00Z" SUCCESS '.reviews = [$rev]' \
    --argjson rev "$(review 5 "nathanpayne-codex" CHANGES_REQUESTED "2026-10-13T07:00:00Z" "$(sha 114)")"
  # 115: CodeRabbit rate-limit notice 10 minutes ago → waiting-on-bot (bot activity, no verdict)
  pr 115 "2026-10-13T11:40:00Z" SUCCESS '.issue_comments = [$c]' \
    --argjson c "$(comment 15 "$RABBIT" "2026-10-13T11:50:00Z" 'Rate limit exceeded; please try again in 12 minutes.')"
  # 117: Merge clearance gate check succeeded on head although the Phase 4 gate fails (under-threshold lane) → merge
  pr 117 "2026-10-13T06:00:00Z" SUCCESS '.reviews = [$rev] | .merge_gate_check = "success" | .gate = {exit: 1, reason: "gate (c): no Codex signal on HEAD"}' \
    --argjson rev "$(review 7 "nathanpayne-claude" APPROVED "2026-10-13T07:00:00Z" "$(sha 117)")"
  # 118: Phase 4 gate passes but the Merge clearance gate check failed on head → investigate, never merge
  pr 118 "2026-10-13T06:00:00Z" SUCCESS '.reviews = [$rev] | .merge_gate_check = "failure" | .gate = {exit: 0, reason: ""}' \
    --argjson rev "$(review 8 "nathanpayne-claude" APPROVED "2026-10-13T07:00:00Z" "$(sha 118)")"
  # 119: CHANGES_REQUESTED on an older commit, answered by a later push; nothing requested on the new head → request codex
  pr 119 "2026-10-13T06:00:00Z" SUCCESS '.reviews = [$rev]' \
    --argjson rev "$(review 9 "nathanpayne-codex" CHANGES_REQUESTED "2026-10-13T04:00:00Z" "$(sha 219)")"
  # 120: handoff, then a Codex summary edit and a CodeRabbit acknowledgement after it → still waiting-on-human
  pr 120 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$h, $s] | .review_comments = [$f, $r, $ack]' \
    --argjson h "$(comment 16 "nathanpayne-claude" "2026-10-13T06:00:00Z" $'Next action: owner decision on the schema.\n\n[mergepath-handoff]')" \
    --argjson s "$(comment 17 "$CODEX" "2026-10-13T05:30:00Z" "$SUMMARY_RUNNING" "2026-10-13T07:00:00Z")" \
    --argjson f "$(inline 9 "$RABBIT" "2026-10-13T05:10:00Z" "$(sha 120)" null)" \
    --argjson r "$(inline 10 "$AUTHOR" "2026-10-13T05:20:00Z" "$(sha 120)" 9)" \
    --argjson ack "$(inline 11 "$RABBIT" "2026-10-13T07:30:00Z" "$(sha 120)" 9)"
  # 121: handoff superseded by a later push → the handoff no longer holds
  pr 121 "2026-10-13T07:00:00Z" SUCCESS '.issue_comments = [$h]' \
    --argjson h "$(comment 18 "nathanpayne-claude" "2026-10-13T06:00:00Z" '[mergepath-handoff] next: rebase')"
  # 122: stale @codex review on a RED head → push fix, not another request
  pr 122 "2026-10-13T05:00:00Z" FAILURE '.issue_comments = [$c]' \
    --argjson c "$(comment 19 "$AUTHOR" "2026-10-13T05:10:00Z" '@codex review')"
  # 124: handoff, then a BODY-LESS bot review wrapper (CodeRabbit acknowledging a resolve) → still waiting-on-human
  pr 124 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$h] | .reviews = [$w]' \
    --argjson h "$(comment 20 "nathanpayne-claude" "2026-10-13T06:00:00Z" '[mergepath-handoff] owner decision needed')" \
    --argjson w "$(review 11 "$RABBIT" COMMENTED "2026-10-13T07:00:00Z" "$(sha 124)" "")"
  # 125: Codex finding answered by a registered reviewer identity, not the author login → not unanswered
  pr 125 "2026-10-13T05:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f, $r] | .gate = {exit: 1, reason: "gate (b): no APPROVED review"}' \
    --argjson rev "$(review 12 "$CODEX" COMMENTED "2026-10-13T05:30:00Z" "$(sha 125)")" \
    --argjson f "$(inline 13 "$CODEX" "2026-10-13T05:30:00Z" "$(sha 125)" null)" \
    --argjson r "$(inline 14 "nathanpayne-claude" "2026-10-13T05:40:00Z" "$(sha 125)" 13)"
  # 126: CodeRabbit rate-limit notice hours old, no failover request → investigate, never an automatic Codex request
  pr 126 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$c]' \
    --argjson c "$(comment 21 "$RABBIT" "2026-10-13T05:10:00Z" 'Rate limit exceeded; please try again in 12 minutes.')"
  # 127: a fork PR, hours stale on a verdict → waiting-on-human (the contributor owns the head)
  pr 127 "2026-10-13T04:00:00Z" SUCCESS '.fork = true | .head_repo = "evil/demo" | .reviews = [$rev]' \
    --argjson rev "$(review 13 "$CODEX" COMMENTED "2026-10-13T04:30:00Z" "$(sha 127)")"
  # 128: same-repo PR authored by someone other than the configured author → waiting-on-human
  pr 128 "2026-10-13T04:00:00Z" SUCCESS '.author = "octocat"'
  # 129: no CI at all on the head (rollup NONE), hours old, no Codex signal → request codex
  pr 129 "2026-10-13T05:00:00Z" NONE
  # 130: a Codex finding EDITED after the agent replied → the old reply no longer answers it
  pr 130 "2026-10-13T05:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f, $r]' \
    --argjson rev "$(review 14 "$CODEX" COMMENTED "2026-10-13T05:30:00Z" "$(sha 130)")" \
    --argjson f "$(inline 15 "$CODEX" "2026-10-13T05:30:00Z" "$(sha 130)" null "2026-10-13T06:30:00Z")" \
    --argjson r "$(inline 16 "nathanpayne-claude" "2026-10-13T05:40:00Z" "$(sha 130)" 15)"
  # 123: only a CodeRabbit review on the head, CI green, hours old → head-unrequested / request codex (not a Codex signal)
  pr 123 "2026-10-13T05:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f]' \
    --argjson rev "$(review 10 "$RABBIT" COMMENTED "2026-10-13T05:20:00Z" "$(sha 123)")" \
    --argjson f "$(inline 12 "$RABBIT" "2026-10-13T05:20:00Z" "$(sha 123)" null)"
} | jq -s --arg repo "$REPO" --arg now "$NOW" '{schema: "stalled-prs/v1", repo: $repo, fetched_at: $now, prs: .}' > "$TMP/snapshot.json"

if ! jq -e '.prs | length == 30' "$TMP/snapshot.json" >/dev/null; then
  echo "FAIL: fixture snapshot did not assemble: $(jq -c . "$TMP/snapshot.json" 2>&1 | head -c 300)" >&2
  exit 1
fi

set +e
bash "$FINDER" --input "$TMP/snapshot.json" --json --now "$NOW" --threshold-minutes 60 > "$TMP/report.json" 2>"$TMP/report.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.schema == "stalled-prs-report/v1" and .repo == "octo/demo"' "$TMP/report.json" >/dev/null; then
  pass "fixture replay classifies and exits 1 when something is stalled"
else
  fail "fixture replay (rc=$rc): $(cat "$TMP/report.err")"
fi

# expect <pr> <jq predicate over that PR's record>
expect() {
  local n="$1" check="$2" rec
  rec=$(jq -c --argjson n "$n" '[.prs[] | select(.number == $n)][0] // null' "$TMP/report.json")
  if [ "$rec" = "null" ]; then
    fail "#$n: missing from the report"
    return
  fi
  if [ "$(printf '%s' "$rec" | jq "$check")" = "true" ]; then
    pass "#$n: $check"
  else
    fail "#$n: $check — got $rec"
  fi
}

expect 101 '.class == "stalled" and .reason == "unanswered-verdict" and .turn == "agent"'
expect 101 '.next_action == "push fix" and .next_action_detail == "2 unanswered finding(s) on head"'
expect 101 '(.unanswered_findings | map(.id)) == [1, 2] and .codex_signal_on_head == true'
expect 101 '.newest.kind == "review:commented" and .newest.actor == "chatgpt-codex-connector[bot]" and .newest.age_seconds == 36900'
expect 116 '.class == "stalled" and .reason == "idle" and .newest.kind == "author-reply" and .next_action == "push fix" and .next_action_detail == "1 unanswered finding(s) on head" and (.unanswered_findings | map(.id)) == [6]'
expect 102 '.class == "live" and .turn == "agent" and .next_action == "push fix"'
expect 103 '.class == "waiting-on-ci" and .turn == "machine" and .next_action == "wait"'
expect 104 '.class == "waiting-on-bot" and .request_outstanding == true and .next_action == "wait"'
expect 105 '.class == "stalled" and .reason == "unanswered-verdict" and .next_action == "merge"'
expect 106 '.class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex" and .codex_signal_on_head == false'
expect 107 '.class == "waiting-on-human" and .reason == "handoff posted" and .turn == "human"'
expect 108 '.class == "waiting-on-human" and .reason == "label human-hold"'
if jq -e '[.prs[] | select(.number == 109)] | length == 0' "$TMP/report.json" >/dev/null; then
  pass "#109: draft PRs are excluded"
else
  fail "#109: draft PR must be excluded"
fi
expect 110 '.class == "stalled" and .codex_signal_on_head == true and .newest.kind == "verdict-comment"'
expect 110 '.next_action == "investigate" and (.next_action_detail | contains("gate (b)"))'
expect 111 '.class == "stalled" and .reason == "request-unanswered" and .turn == "machine" and .next_action == "request codex"'
expect 112 '.class == "stalled" and .next_action == "push fix" and .next_action_detail == "head check rollup FAILURE"'
expect 113 '.class == "waiting-on-bot" and .reason == "Codex reports the head Running" and .codex_signal_on_head == true'
expect 114 '.class == "stalled" and .next_action == "push fix" and .next_action_detail == "latest verdict requested changes on head"'
expect 115 '.class == "waiting-on-bot" and .newest.kind == "bot-rate-limited"'
expect 117 '.class == "stalled" and .next_action == "merge" and (.next_action_detail | startswith("Merge clearance gate check success"))'
expect 118 '.class == "stalled" and .next_action == "investigate" and (.next_action_detail | contains("Merge clearance gate check failed"))'
expect 119 '.class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex"'
expect 120 '.class == "waiting-on-human" and .reason == "handoff posted" and .next_action == "wait"'
expect 121 '.class == "stalled" and .reason == "head-unrequested"'
expect 122 '.class == "stalled" and .reason == "request-unanswered" and .next_action == "push fix" and .next_action_detail == "head check rollup FAILURE"'
expect 123 '.class == "stalled" and .reason == "unanswered-verdict" and .codex_signal_on_head == false and .next_action == "push fix" and .next_action_detail == "1 unanswered finding(s) on head"'
expect 105 '.next_action_detail | startswith("no Merge clearance gate check in this repo")'
expect 124 '.class == "waiting-on-human" and .reason == "handoff posted"'
expect 125 '.class == "stalled" and (.unanswered_findings | length) == 0 and .next_action == "investigate"'
expect 126 '.class == "stalled" and .reason == "rate-limit-stale" and .next_action == "investigate" and (.next_action_detail | contains("coderabbit-wait.sh"))'
expect 127 '.class == "waiting-on-human" and .reason == "fork PR: the contributor owns the head" and .turn == "human" and .next_action == "wait"'
expect 128 '.class == "waiting-on-human" and .reason == "not agent-authored (octocat)" and .next_action == "wait"'
expect 129 '.class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex" and .next_action_detail == "no Codex signal on head; no CI on head"'
expect 130 '.class == "stalled" and (.unanswered_findings | map(.id)) == [15] and .next_action == "push fix"'

if jq -e '[.prs[] | .number] == [101, 116, 129, 111, 122, 126, 123, 125, 130, 110, 112, 119, 105, 114, 117, 118, 121, 106, 128, 127, 108, 124, 120, 107, 104, 102, 113, 103, 115]' "$TMP/report.json" >/dev/null; then
  pass "report is ordered stalled-first, oldest newest-event first"
else
  fail "report order: $(jq -c '[.prs[] | .number]' "$TMP/report.json")"
fi

set +e
bash "$FINDER" --input "$TMP/snapshot.json" --now "$NOW" > "$TMP/human.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -Fq '#101  stalled  10h15m  review:commented by chatgpt-codex-connector[bot] at 2026-10-13T01:45:00Z  head 0000000  next: push fix — 2 unanswered finding(s) on head' "$TMP/human.txt" \
   && grep -Fq 'stalled-prs: octo/demo — 29 open non-draft PR(s), threshold 60m, now 2026-10-13T12:00:00Z' "$TMP/human.txt"; then
  pass "human output carries one line per PR with class, age, newest event, head and next action"
else
  fail "human output (rc=$rc): $(head -3 "$TMP/human.txt")"
fi

# Threshold is configurable: at 12 hours nothing in the fixture is stalled on
# an agent's turn except the machine waits that outlived it.
set +e
bash "$FINDER" --input "$TMP/snapshot.json" --json --now "$NOW" --threshold-minutes 720 > "$TMP/report-720.json" 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ] && jq -e '[.prs[] | select(.class == "stalled")] | length == 0' "$TMP/report-720.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 101)][0].class == "live"' "$TMP/report-720.json" >/dev/null; then
  pass "a 12-hour threshold reports nothing stalled and exits 0"
else
  fail "threshold 720 (rc=$rc): $(jq -c '[.prs[] | {number, class}]' "$TMP/report-720.json" 2>/dev/null)"
fi

set +e
bash "$FINDER" --input "$TMP/snapshot.json" --now "not-a-time" >/dev/null 2>&1; rc_now=$?
bash "$FINDER" --input "$TMP/snapshot.json" --threshold-minutes 0 >/dev/null 2>&1; rc_thr=$?
printf '{"schema":"other"}' > "$TMP/bad.json"
bash "$FINDER" --input "$TMP/bad.json" >/dev/null 2>&1; rc_bad=$?
bash "$FINDER" --input "$TMP/missing.json" >/dev/null 2>&1; rc_missing=$?
set -e
if [ "$rc_now" -eq 2 ] && [ "$rc_thr" -eq 2 ] && [ "$rc_bad" -eq 3 ] && [ "$rc_missing" -eq 3 ]; then
  pass "bad --now/--threshold are usage errors (2); unreadable or foreign input is a read failure (3)"
else
  fail "argument validation (now=$rc_now thr=$rc_thr bad=$rc_bad missing=$rc_missing)"
fi

# --- resume: selection and work orders -------------------------------------

set +e
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" > "$TMP/resume.txt" 2>"$TMP/resume.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fq 'PR:          octo/demo#101 — PR 101' "$TMP/resume.txt" \
   && grep -Fq 'Next action: push fix — 2 unanswered finding(s) on head' "$TMP/resume.txt" \
   && grep -Fq 'scripts/resolve-pr-threads.sh 101 --resolve-actioned' "$TMP/resume.txt" \
   && grep -Fq 'https://github.com/octo/demo/pull/1#discussion_r1' "$TMP/resume.txt" \
   && grep -Fq 'worktree add $HOME/GitHub/.demo-worktrees/pr-101 feat/101' "$TMP/resume.txt" \
   && grep -Fq '[mergepath-handoff]' "$TMP/resume.txt"; then
  pass "resume picks the oldest stalled PR and prints its push-fix work order"
else
  fail "resume default selection (rc=$rc): $(head -5 "$TMP/resume.txt") $(cat "$TMP/resume.err")"
fi

set +e
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --pr 105 --json > "$TMP/resume-105.txt" 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fq "gh pr merge 105 --repo octo/demo --squash --delete-branch --match-head-commit $(sha 105)" "$TMP/resume-105.txt" \
   && grep -Fq 'scripts/review-feedback-accounting.sh 105' "$TMP/resume-105.txt" \
   && grep -Fq 'scripts/phase-4b-classifier.sh 105' "$TMP/resume-105.txt" \
   && grep -Fq 'this script never merges' "$TMP/resume-105.txt" \
   && grep -Fq '"next_action": "merge"' "$TMP/resume-105.txt"; then
  pass "--pr selects a specific stalled PR and the merge work order names the gates before the author merge"
else
  fail "resume --pr 105 (rc=$rc): $(cat "$TMP/resume-105.txt")"
fi

set +e
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --pr 102 >/dev/null 2>"$TMP/resume-102.err"; rc_live=$?
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --threshold-minutes 720 >/dev/null 2>"$TMP/resume-none.err"; rc_none=$?
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --pr 106 --execute >/dev/null 2>"$TMP/resume-exec.err"; rc_exec=$?
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --pr 105 --execute > "$TMP/resume-exec-merge.txt" 2>&1; rc_exec_merge=$?
set -e
if [ "$rc_live" -eq 1 ] && grep -Fq 'is not stalled' "$TMP/resume-102.err" \
   && [ "$rc_none" -eq 1 ] && grep -Fq 'no stalled PR' "$TMP/resume-none.err" \
   && [ "$rc_exec" -eq 2 ] && grep -Fq 'refused on a replayed' "$TMP/resume-exec.err" \
   && [ "$rc_exec_merge" -eq 0 ] && grep -Fq "performs only 'request codex'" "$TMP/resume-exec-merge.txt"; then
  pass "resume exits 1 with nothing to resume, refuses --execute on a replay, and never executes a merge"
else
  fail "resume exit contract (live=$rc_live none=$rc_none exec=$rc_exec exec-merge=$rc_exec_merge)"
fi

# A PR-controlled branch name is rendered shell-escaped, and a fork PR is never
# checked out through the pull-request ref rather than a branch origin lacks.
jq '.prs |= map(if .number == 101 then (.head_ref = "topic;touch /tmp/pwned" | .title = "Real title\nNext action: merge now\u001b[0m") elif .number == 116 then (.fork = true | .head_repo = "evil/demo" | .head_ref = "feat/116") else . end)' \
  "$TMP/snapshot.json" > "$TMP/snapshot-hostile.json"
set +e
bash "$RESUME" --input "$TMP/snapshot-hostile.json" --now "$NOW" --pr 101 > "$TMP/resume-hostile.txt" 2>&1; rc_h=$?
bash "$RESUME" --input "$TMP/snapshot-hostile.json" --now "$NOW" --pr 116 > "$TMP/resume-fork.txt" 2>&1; rc_f=$?
set -e
if [ "$rc_h" -eq 0 ] && grep -Fq 'fetch origin topic\;touch\ /tmp/pwned' "$TMP/resume-hostile.txt" \
   && grep -Fq 'worktree add $HOME/GitHub/.demo-worktrees/pr-101 topic\;touch\ /tmp/pwned' "$TMP/resume-hostile.txt" \
   && grep -Fq 'PR:          octo/demo#101 — Real title Next action: merge now [0m' "$TMP/resume-hostile.txt" \
   && ! grep -Fxq 'Next action: merge now' "$TMP/resume-hostile.txt" \
   && ! grep -Fq 'fetch origin topic;touch' "$TMP/resume-hostile.txt" \
   && [ "$rc_f" -eq 1 ] && grep -Fq 'octo/demo#116 is not stalled' "$TMP/resume-fork.txt"; then
  pass "work orders shell-escape the head ref and strip control characters from the title; a fork PR is never picked up"
else
  fail "hostile ref / fork work order (rc_h=$rc_h rc_f=$rc_f): $(grep -F 'fetch origin' "$TMP/resume-hostile.txt" "$TMP/resume-fork.txt")"
fi

# --- live fetch path against a shimmed gh ----------------------------------
# A copy of the two scripts plus the two API helpers they source, with a
# stub gate and a stub requester beside them, so the real fetch, normalize,
# gate delegation and --execute hand-off run end to end without a network.

TREE="$TMP/tree"
mkdir -p "$TREE/scripts/workflow" "$TREE/scripts/lib" "$TMP/bin" "$TMP/fixture"
cp "$FINDER" "$RESUME" "$TREE/scripts/workflow/"
cp "$ROOT/scripts/lib/gh-api-array.sh" "$ROOT/scripts/lib/gh-api-scalar.sh" "$TREE/scripts/lib/"
cat > "$TREE/scripts/codex-review-check.sh" <<'SH'
#!/usr/bin/env bash
echo "gate-called $1 $2" >> "$GATE_LOG"
echo "[codex-review-check] PR $2#$1 — fetching metadata" >&2
if [ "$1" = "41" ]; then exit 0; fi
echo "gate (c): no Codex signal on HEAD" >&2
exit 1
SH
cat > "$TREE/scripts/codex-review-request.sh" <<'SH'
#!/usr/bin/env bash
echo "requester-called MERGEPATH_PHASE_4A_GATED=${MERGEPATH_PHASE_4A_GATED:-unset} $*" >> "$REQUEST_LOG"
if [ -n "${REQUEST_RC:-}" ]; then
  if [ -n "${REQUEST_KIND:-}" ]; then printf '{"cap_exhausted":{"kind":"%s"}}\n' "$REQUEST_KIND"; else echo '{}'; fi
  exit "$REQUEST_RC"
fi
echo '{"trigger_posted":true}'
exit 0
SH
chmod +x "$TREE"/scripts/*.sh "$TREE"/scripts/workflow/*.sh
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# Hermetic gh shim: canned responses keyed on the request shape.
args="$*"
echo "$args" >> "$GH_LOG"
case "$args" in
  *"api graphql"*)          printf '%s' "$(cat "$FIXTURE/rollup-$(printf '%s' "$args" | sed -n 's/.*number=\([0-9]*\).*/\1/p')")" ;;
  *"/activity?"*)          cat "$FIXTURE/activity-$(printf '%s' "$args" | sed -n 's/.*feat%2F\([0-9]*\).*/\1/p').json" ;;
  *"/check-runs"*)          cat "$FIXTURE/check-runs-$(printf '%s' "$args" | sed -n 's/.*commits\/\(..\).*/\1/p').json" ;;
  *"/commits/"*)            echo "gh shim: the commit date must never be read for push time" >&2; exit 1 ;;
  *"/pulls?state=open"*)    cat "$FIXTURE/pulls.json" ;;
  *"/pulls/41/reviews"*)    echo '[{"id":9,"state":"APPROVED","submitted_at":"2026-10-13T07:00:00Z","commit_id":"4141414141414141414141414141414141414141","body":"LGTM","user":{"login":"nathanpayne-claude","type":"User"}}]' ;;
  *"/reviews"*)             echo '[]' ;;
  *"/issues/"*"/comments"*) echo '[]' ;;
  *"/pulls/"*"/comments"*)  echo '[]' ;;
  *) echo "gh shim: unhandled request: $args" >&2; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/gh"
cat > "$TMP/fixture/pulls.json" <<'JSON'
[{"number":41,"title":"Approved and idle","html_url":"https://github.com/octo/demo/pull/41","draft":false,
  "user":{"login":"nathanjohnpayne"},"head":{"sha":"4141414141414141414141414141414141414141","ref":"feat/41","repo":{"full_name":"octo/demo"}},"base":{"repo":{"full_name":"octo/demo"}},"labels":[{"name":"size:S"}]},
 {"number":42,"title":"Pushed and forgotten","html_url":"https://github.com/octo/demo/pull/42","draft":false,
  "user":{"login":"nathanjohnpayne"},"updated_at":"2026-10-13T06:00:00Z","head":{"sha":"4242424242424242424242424242424242424242","ref":"feat/42","repo":{"full_name":"octo/demo"}},"base":{"repo":{"full_name":"octo/demo"}},"labels":[]},
 {"number":43,"title":"Draft","html_url":"https://github.com/octo/demo/pull/43","draft":true,
  "user":{"login":"nathanjohnpayne"},"updated_at":"2026-10-13T06:00:00Z","head":{"sha":"4343434343434343434343434343434343434343","ref":"feat/43","repo":{"full_name":"octo/demo"}},"base":{"repo":{"full_name":"octo/demo"}},"labels":[]},
 {"number":44,"title":"Future-dated head, no checks","html_url":"https://github.com/octo/demo/pull/44","draft":false,"updated_at":"2026-10-13T05:00:00Z",
  "user":{"login":"nathanjohnpayne"},"head":{"sha":"4444444444444444444444444444444444444444","ref":"feat/44","repo":{"full_name":"octo/demo"}},"base":{"repo":{"full_name":"octo/demo"}},"labels":[]},
 {"number":42,"title":"Pushed and forgotten (repeated by a page boundary)","html_url":"https://github.com/octo/demo/pull/42","draft":false,
  "user":{"login":"nathanjohnpayne"},"updated_at":"2026-10-13T06:00:00Z","head":{"sha":"4242424242424242424242424242424242424242","ref":"feat/42","repo":{"full_name":"octo/demo"}},"base":{"repo":{"full_name":"octo/demo"}},"labels":[]}]
JSON
# 41: three check runs on the head, the merge gate newest and green; 42: no
# check runs at all (push time falls back to the commit date); 43: draft;
# 44: no check runs and a FUTURE-dated commit (bounded by the PR's server-set
# updated_at, a stable value, so it neither stays live until that date nor
# re-dates itself to each run's clock).
cat > "$TMP/fixture/check-runs-41.json" <<'JSON'
{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-13T06:00:00Z","completed_at":"2026-10-13T06:20:00Z"}
{"name":"Merge clearance gate","status":"completed","conclusion":"failure","started_at":"2026-10-13T06:01:00Z","completed_at":"2026-10-13T06:02:00Z"}
{"name":"Merge clearance gate","status":"completed","conclusion":"success","started_at":"2026-10-13T07:05:00Z","completed_at":"2026-10-13T07:06:00Z"}
JSON
: > "$TMP/fixture/check-runs-42.json"
# Push activity: 41 has a server push entry for its head (05:58) plus one for
# an older SHA; 42-44 have none for their heads, so 42 and 44 fall through to
# the PR's updated_at (no check runs either).
printf '[{"after":"4141414141414141414141414141414141414141","timestamp":"2026-10-13T05:58:00Z","activity_type":"push"},{"after":"0000000000000000000000000000000000000041","timestamp":"2026-10-12T05:00:00Z","activity_type":"push"}]' > "$TMP/fixture/activity-41.json"
printf '[{"after":"9999999999999999999999999999999999999999","timestamp":"2026-10-13T01:00:00Z","activity_type":"push"}]' > "$TMP/fixture/activity-42.json"
printf '[]' > "$TMP/fixture/activity-43.json"
printf '[]' > "$TMP/fixture/activity-44.json"
: > "$TMP/fixture/check-runs-43.json"
: > "$TMP/fixture/check-runs-44.json"
printf 'SUCCESS' > "$TMP/fixture/rollup-44"
printf 'SUCCESS' > "$TMP/fixture/rollup-41"
printf 'SUCCESS' > "$TMP/fixture/rollup-42"
printf 'PENDING' > "$TMP/fixture/rollup-43"

: > "$TMP/gh.log"; : > "$TMP/gate.log"; : > "$TMP/request.log"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
  bash "$TREE/scripts/workflow/stalled-prs.sh" --repo "$REPO" --json --now "$NOW" --dump "$TMP/live-dump.json" > "$TMP/live.json" 2>"$TMP/live.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] \
   && jq -e '[.prs[] | .number] == [44, 42, 41]' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 41)][0] | .class == "stalled" and .next_action == "merge" and .gate.exit == 0 and .head_ref == "feat/41" and .merge_gate_check == "success" and .head_pushed_at == "2026-10-13T05:58:00Z" and .head_pushed_at_source == "push-activity" and .fork == false' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 42)][0] | .class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex" and .gate.exit == 1 and (.gate.reason | contains("gate (c)")) and .merge_gate_check == "absent" and .head_pushed_at == "2026-10-13T06:00:00Z" and .head_pushed_at_source == "pr-updated-at" and .fork == false' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 44)][0] | .class == "stalled" and .reason == "head-unrequested" and .head_pushed_at == "2026-10-13T05:00:00Z" and .head_pushed_at_source == "pr-updated-at"' "$TMP/live.json" >/dev/null; then
  pass "live fetch normalizes the open PRs, delegates merge readiness to the gate, and records its reason"
else
  fail "live fetch (rc=$rc): $(cat "$TMP/live.err") $(jq -c '[.prs[] | {number, class, next_action, gate}]' "$TMP/live.json" 2>/dev/null)"
fi

if [ "$(grep -c 'gate-called' "$TMP/gate.log")" -eq 3 ] \
   && grep -Fq 'gate-called 41 octo/demo' "$TMP/gate.log" \
   && grep -Fq 'gate-called 44 octo/demo' "$TMP/gate.log" \
   && [ "$(grep -c -- '--paginate repos/octo/demo/pulls?state=open' "$TMP/gh.log")" -eq 1 ] \
   && [ "$(grep -c -- '--paginate repos/octo/demo/pulls/41/reviews' "$TMP/gh.log")" -eq 1 ] \
   && [ "$(grep -c -- '--paginate repos/octo/demo/issues/41/comments' "$TMP/gh.log")" -eq 1 ] \
   && [ "$(grep -c -- '--paginate repos/octo/demo/pulls/41/comments' "$TMP/gh.log")" -eq 1 ] \
   && [ "$(grep -c -- '--paginate repos/octo/demo/commits/4141414141414141414141414141414141414141/check-runs' "$TMP/gh.log")" -eq 1 ] \
   && [ "$(grep -c -- '--paginate repos/octo/demo/pulls/42/reviews' "$TMP/gh.log")" -eq 1 ] \
   && [ "$(grep -c -- '--paginate repos/octo/demo/activity?ref=refs%2Fheads%2Ffeat%2F41&activity_type=push' "$TMP/gh.log")" -eq 1 ] \
   && ! grep -q 'repos/octo/demo/commits/[0-9]*$\|repos/octo/demo/commits/[0-9]* ' "$TMP/gh.log"; then
  pass "every list read is paginated, a PR repeated across pages is read once, and the gate runs once per stalled agent-turn PR"
else
  fail "read discipline: $(cat "$TMP/gh.log" "$TMP/gate.log")"
fi

if jq -e '.schema == "stalled-prs/v1" and .repo == "octo/demo" and ([.prs[] | .number] == [41, 42, 43, 44]) and ([.prs[] | select(.number == 41)][0].gate.exit == 0)' "$TMP/live-dump.json" >/dev/null; then
  : > "$TMP/gate.log"
  set +e
  bash "$FINDER" --input "$TMP/live-dump.json" --json --now "$NOW" > "$TMP/replay.json" 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 1 ] && [ "$(jq -c '[.prs[] | {number, class, next_action}]' "$TMP/replay.json")" = "$(jq -c '[.prs[] | {number, class, next_action}]' "$TMP/live.json")" ] \
     && [ ! -s "$TMP/gate.log" ]; then
    pass "--dump writes a replayable snapshot that --input classifies identically without running the gate"
  else
    fail "dump replay (rc=$rc): $(jq -c '[.prs[] | {number, class, next_action}]' "$TMP/replay.json" 2>/dev/null)"
  fi
else
  fail "--dump did not write a stalled-prs/v1 snapshot with the gate result recorded"
fi

: > "$TMP/gh.log"; : > "$TMP/gate.log"; : > "$TMP/request.log"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" REQUEST_LOG="$TMP/request.log" \
  bash "$TREE/scripts/workflow/resume-stalled-pr.sh" --repo "$REPO" --now "$NOW" --pr 42 --execute > "$TMP/resume-live.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fxq 'requester-called MERGEPATH_PHASE_4A_GATED=true --trigger-only 42 octo/demo' "$TMP/request.log" \
   && grep -Fq 'Next action: request codex' "$TMP/resume-live.txt"; then
  pass "--execute posts the Codex request through the requester with the Phase 4a gate flag, trigger-only"
else
  fail "resume --execute (rc=$rc): $(cat "$TMP/request.log") $(tail -5 "$TMP/resume-live.txt")"
fi

: > "$TMP/request.log"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" REQUEST_LOG="$TMP/request.log" \
  bash "$TREE/scripts/workflow/resume-stalled-pr.sh" --repo "$REPO" --now "$NOW" --pr 41 --execute > "$TMP/resume-live-41.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/request.log" ] && grep -Fq 'PR:          octo/demo#41' "$TMP/resume-live-41.txt" \
   && grep -Fq "performs only 'request codex'" "$TMP/resume-live-41.txt"; then
  pass "--execute on a merge-ready PR prints the gates and performs nothing"
else
  fail "resume --execute merge-ready (rc=$rc): $(tail -5 "$TMP/resume-live-41.txt")"
fi

# --execute preserves the requester's policy refusals as routing outcomes
# (exit 4 + a `next:` line + the --json execute record), never as an
# infrastructure failure; a genuine requester failure stays exit 3.
run_exec() { # <rc> <kind> <out>
  : > "$TMP/request.log"
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" REQUEST_LOG="$TMP/request.log" \
    REQUEST_RC="$1" REQUEST_KIND="$2" \
    bash "$TREE/scripts/workflow/resume-stalled-pr.sh" --repo "$REPO" --now "$NOW" --pr 42 --execute --json > "$3" 2>&1
  local r=$?
  set -e
  return "$r"
}
rc_c=0; run_exec 7 request-ceiling "$TMP/exec-ceiling.txt" || rc_c=$?
rc_b=0; run_exec 7 blocking-reviews "$TMP/exec-blocking.txt" || rc_b=$?
rc_u=0; run_exec 6 "" "$TMP/exec-unaccounted.txt" || rc_u=$?
rc_i=0; run_exec 3 "" "$TMP/exec-infra.txt" || rc_i=$?
if [ "$rc_c" -eq 4 ] && grep -Fq 'next: phase 4b — the request ceiling is spent: run scripts/phase-4b-review.sh 42 --repo octo/demo' "$TMP/exec-ceiling.txt" \
   && grep -Fq '"requester_exit": 7' "$TMP/exec-ceiling.txt" && grep -Fq '"cap_kind": "request-ceiling"' "$TMP/exec-ceiling.txt" \
   && [ "$rc_b" -eq 4 ] && grep -Fq 'next: human tiebreaker' "$TMP/exec-blocking.txt" && grep -Fq '[mergepath-handoff]' "$TMP/exec-blocking.txt" \
   && [ "$rc_u" -eq 4 ] && grep -Fq 'next: disposition findings' "$TMP/exec-unaccounted.txt" \
   && [ "$rc_i" -eq 3 ] && grep -Fq 'exited 3 (infrastructure)' "$TMP/exec-infra.txt"; then
  pass "--execute maps requester exit 7 (by cap kind) and 6 to routing outcomes (exit 4) and keeps a real failure at exit 3"
else
  fail "requester exit mapping (ceiling=$rc_c blocking=$rc_b unaccounted=$rc_u infra=$rc_i): $(tail -3 "$TMP/exec-ceiling.txt")"
fi

# A failed list read must be a status, never an empty report (#831 contract).
cat > "$TMP/bin/gh-broken" <<'SH'
#!/usr/bin/env bash
echo "gh: Internal Server Error (HTTP 500)" >&2
exit 1
SH
chmod +x "$TMP/bin/gh-broken"
mkdir -p "$TMP/bin-broken" && cp "$TMP/bin/gh-broken" "$TMP/bin-broken/gh"
set +e
PATH="$TMP/bin-broken:$PATH" GH_TOKEN=test-token bash "$TREE/scripts/workflow/stalled-prs.sh" --repo "$REPO" --json --now "$NOW" > "$TMP/broken.json" 2>"$TMP/broken.err"
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ ! -s "$TMP/broken.json" ] && grep -Fq 'failed to fetch open pull requests' "$TMP/broken.err"; then
  pass "an unreadable PR list exits 3 with nothing on stdout"
else
  fail "unreadable list (rc=$rc): $(cat "$TMP/broken.err")"
fi

echo "test_stalled_pr_resume: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
