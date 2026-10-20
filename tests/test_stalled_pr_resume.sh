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
# canned REST responses, with a stub gate script, and asserts the
# normalization, the pagination discipline, the gate delegation and the work
# orders the read-only resume entry point prints. Hermetic: no network.

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
  # 131: @coderabbitai review, then CodeRabbit refuses on a rate limit; hours later nothing → rate-limit-stale / investigate
  #      (the outstanding trigger must not turn into an automatic Codex request)
  pr 131 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$t, $c]' \
    --argjson t "$(comment 22 "$AUTHOR" "2026-10-13T05:05:00Z" '@coderabbitai review')" \
    --argjson c "$(comment 23 "$RABBIT" "2026-10-13T05:06:00Z" 'Rate limit exceeded; please try again in 30 minutes.')"
  # 132: same, but the sanctioned failover posted @codex review after the refusal and Codex never answered → request codex
  pr 132 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$t, $c, $f]' \
    --argjson t "$(comment 24 "$AUTHOR" "2026-10-13T05:05:00Z" '@coderabbitai review')" \
    --argjson c "$(comment 25 "$RABBIT" "2026-10-13T05:06:00Z" 'Rate limit exceeded; please try again in 30 minutes.')" \
    --argjson f "$(comment 26 "$AUTHOR" "2026-10-13T05:07:00Z" '@codex review')"
  # 133: Codex Review Summary left at Running, but a head-anchored Codex findings review landed after it → push fix
  pr 133 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$sum] | .reviews = [$rev] | .review_comments = [$f]' \
    --argjson sum "$(comment 27 "$CODEX" "2026-10-13T05:10:00Z" "${SUMMARY_RUNNING//$(sha 113 | cut -c1-7)/$(sha 133 | cut -c1-7)}" "2026-10-13T05:11:00Z")" \
    --argjson rev "$(review 15 "$CODEX" COMMENTED "2026-10-13T05:20:00Z" "$(sha 133)")" \
    --argjson f "$(inline 17 "$CODEX" "2026-10-13T05:20:00Z" "$(sha 133)" null)"
  # 134: CodeRabbit refuses on a rate limit, then an UNRELATED human comment lands; hours later →
  #      still rate-limit-stale / investigate (the comment is not the provider recovering)
  pr 134 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$t, $c, $h]' \
    --argjson t "$(comment 28 "$AUTHOR" "2026-10-13T05:05:00Z" '@coderabbitai review')" \
    --argjson c "$(comment 29 "$RABBIT" "2026-10-13T05:06:00Z" 'Rate limit exceeded; please try again in 30 minutes.')" \
    --argjson h "$(comment 30 "octocat" "2026-10-13T05:30:00Z" 'Looks reasonable to me, waiting on the bots.')"
  # 135: same, but CodeRabbit itself recovers with a review after the notice → no longer rate-limited
  pr 135 "2026-10-13T05:00:00Z" SUCCESS '.issue_comments = [$t, $c] | .reviews = [$rev]' \
    --argjson t "$(comment 31 "$AUTHOR" "2026-10-13T05:05:00Z" '@coderabbitai review')" \
    --argjson c "$(comment 32 "$RABBIT" "2026-10-13T05:06:00Z" 'Rate limit exceeded; please try again in 30 minutes.')" \
    --argjson rev "$(review 16 "$RABBIT" COMMENTED "2026-10-13T05:40:00Z" "$(sha 135)")"
  # 136: a handoff marker posted by a BOT, later author activity → still waiting-on-human (any author, any time)
  pr 136 "2026-10-13T07:00:00Z" SUCCESS '.issue_comments = [$h, $a]' \
    --argjson h "$(comment 33 "$CODEX" "2026-10-13T05:00:00Z" $'Handing this round back.\n\n[mergepath-handoff]')" \
    --argjson a "$(comment 34 "$AUTHOR" "2026-10-13T07:30:00Z" 'pushed a follow-up')"
  # 137: a handoff marker carried by an inline review-comment reply (not an issue comment) → waiting-on-human
  pr 137 "2026-10-13T05:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f, $r]' \
    --argjson rev "$(review 17 "$CODEX" COMMENTED "2026-10-13T05:30:00Z" "$(sha 137)")" \
    --argjson f "$(inline 18 "$CODEX" "2026-10-13T05:30:00Z" "$(sha 137)" null)" \
    --argjson r "$(jq -cn --arg c "$(sha 137)" '{id: 19, created_at: "2026-10-13T05:40:00Z", updated_at: "2026-10-13T05:40:00Z", commit_id: $c, original_commit_id: $c, in_reply_to_id: 18, html_url: "https://github.com/octo/demo/pull/1#discussion_r19", body: "Owner decision needed here.\n[mergepath-handoff]", user: {login: "nathanpayne-claude", type: "User"}}')"
  # 123: only a CodeRabbit review on the head, CI green, hours old → head-unrequested / request codex (not a Codex signal)
  pr 123 "2026-10-13T05:00:00Z" SUCCESS '.reviews = [$rev] | .review_comments = [$f]' \
    --argjson rev "$(review 10 "$RABBIT" COMMENTED "2026-10-13T05:20:00Z" "$(sha 123)")" \
    --argjson f "$(inline 12 "$RABBIT" "2026-10-13T05:20:00Z" "$(sha 123)" null)"
} | jq -s --arg repo "$REPO" --arg now "$NOW" '{schema: "stalled-prs/v1", repo: $repo, fetched_at: $now, prs: .}' > "$TMP/snapshot.json"

if ! jq -e '.prs | length == 37' "$TMP/snapshot.json" >/dev/null; then
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
expect 112 '.class == "stalled" and .next_action == "push fix" and .next_action_detail == "required head checks FAILURE"'
expect 113 '.class == "waiting-on-bot" and .reason == "Codex reports the head Running" and .codex_signal_on_head == true'
expect 114 '.class == "stalled" and .next_action == "push fix" and .next_action_detail == "latest verdict requested changes on head"'
expect 115 '.class == "waiting-on-bot" and .newest.kind == "bot-rate-limited"'
expect 117 '.class == "stalled" and .next_action == "merge" and (.next_action_detail | startswith("Merge clearance gate check success"))'
expect 118 '.class == "stalled" and .next_action == "investigate" and (.next_action_detail | contains("Merge clearance gate check failed"))'
expect 119 '.class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex"'
expect 120 '.class == "waiting-on-human" and .reason == "handoff posted" and .next_action == "wait"'
expect 121 '.class == "waiting-on-human" and .reason == "handoff posted"'
expect 122 '.class == "stalled" and .reason == "request-unanswered" and .next_action == "push fix" and .next_action_detail == "required head checks FAILURE"'
expect 123 '.class == "stalled" and .reason == "unanswered-verdict" and .codex_signal_on_head == false and .next_action == "push fix" and .next_action_detail == "1 unanswered finding(s) on head"'
expect 105 '.next_action_detail | startswith("no Merge clearance gate check in this repo")'
expect 124 '.class == "waiting-on-human" and .reason == "handoff posted"'
expect 125 '.class == "stalled" and (.unanswered_findings | length) == 0 and .next_action == "investigate"'
expect 126 '.class == "stalled" and .reason == "rate-limit-stale" and .next_action == "investigate" and (.next_action_detail | contains("coderabbit-wait.sh"))'
expect 127 '.class == "waiting-on-human" and .reason == "fork PR: the contributor owns the head" and .turn == "human" and .next_action == "wait"'
expect 128 '.class == "waiting-on-human" and .reason == "not agent-authored (octocat)" and .next_action == "wait"'
expect 129 '.class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex" and .next_action_detail == "no Codex signal on head; no CI on head"'
expect 130 '.class == "stalled" and (.unanswered_findings | map(.id)) == [15] and .next_action == "push fix"'
expect 131 '.class == "stalled" and .reason == "rate-limit-stale" and .rate_limited == true and .request_outstanding == true and .next_action == "investigate"'
expect 132 '.class == "stalled" and .reason == "request-unanswered" and .rate_limited == false and .next_action == "request codex"'
expect 133 '.class == "stalled" and .reason == "unanswered-verdict" and .next_action == "push fix" and (.unanswered_findings | map(.id)) == [17]'
expect 115 '.reason == "provider rate-limited; no failover request yet"'
expect 134 '.class == "stalled" and .reason == "rate-limit-stale" and .rate_limited == true and .next_action == "investigate"'
expect 136 '.class == "waiting-on-human" and .reason == "handoff posted"'
expect 137 '.class == "waiting-on-human" and .reason == "handoff posted"'
expect 135 '.class == "stalled" and .rate_limited == false and .reason == "unanswered-verdict"'

# A pending check must not mask the same head-anchored feedback that already
# routes to a fix with completed CI. Positive, answered/stale and hold cases
# reuse the original snapshot records, preserving the main ordering fixture.
while IFS='~' read -r mode source_number overlay expected_class expected_reason expected_action expected_turn; do
  jq --argjson n "$source_number" '[.prs[] | select(.number == $n)][0] | .ci_state="PENDING" | '"$overlay" \
    "$TMP/snapshot.json" | jq -s --arg repo "$REPO" '{schema:"stalled-prs/v1",repo:$repo,prs:.}' > "$TMP/pending-$mode.json"
  set +e
  bash "$FINDER" --input "$TMP/pending-$mode.json" --no-gate --json --now "$NOW" \
    > "$TMP/pending-$mode-report.json" 2> "$TMP/pending-$mode.err"
  pending_rc=$?
  set -e
  if [ "$pending_rc" -le 1 ] && jq -e --arg class "$expected_class" --arg reason "$expected_reason" --arg action "$expected_action" --arg turn "$expected_turn" \
    '.prs[0] | .class == $class and .reason == $reason and .next_action == $action and .turn == $turn and .next_action != "merge"' \
    "$TMP/pending-$mode-report.json" >/dev/null; then
    pass "pending CI verdict precedence: $mode"
  else fail "pending CI verdict precedence $mode (rc=$pending_rc): $(cat "$TMP/pending-$mode-report.json") $(cat "$TMP/pending-$mode.err")"; fi
done <<'CASES'
findings~101~.~stalled~unanswered-verdict~push fix~agent
fresh-findings~102~.~live~newest event younger than the threshold~push fix~agent
changes~114~.~stalled~unanswered-verdict~push fix~agent
edited~130~.~stalled~unanswered-verdict~push fix~agent
old-changes~119~.~stalled~ci-pending-stale~investigate~machine
approval~105~.~stalled~ci-pending-stale~investigate~machine
answered~101~.review_comments += [.review_comments[] | .in_reply_to_id=.id | .id += 100 | .user={login:"nathanpayne-codex",type:"User"} | .created_at="2026-10-13T01:50:00Z" | .updated_at=.created_at]~stalled~ci-pending-stale~investigate~machine
active-summary~101~.issue_comments += [{id:100,user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},created_at:"2026-10-13T11:45:00Z",updated_at:"2026-10-13T11:45:00Z",body:("<!-- codex-pull-request-review-summary -->\n| | Status | Commit | Trigger |\n|---|---|---|---|\n| 📝 **Code Review** | **Running** | `" + .head_sha + "` | @codex review |")}]~waiting-on-bot~Codex reports the head Running~wait~machine
before-push~101~.head_pushed_at="2026-10-13T03:00:00Z"~stalled~ci-pending-stale~investigate~machine
same-second~101~.reviews[].submitted_at=.head_pushed_at | .review_comments[] |= (.created_at="2026-10-13T01:00:00Z" | .updated_at=.created_at)~stalled~ci-pending-stale~investigate~machine
stale-anchor~101~.reviews[].commit_id="old-head" | .review_comments[] |= (.commit_id="old-head" | .original_commit_id="old-head")~stalled~ci-pending-stale~investigate~machine
human-hold~101~.labels=["human-hold"]~waiting-on-human~label human-hold~wait~human
CASES

if jq -e '[.prs[] | .number] == [101, 116, 129, 131, 132, 111, 122, 126, 133, 123, 134, 125, 130, 135, 110, 112, 119, 105, 114, 117, 118, 106, 128, 127, 137, 108, 121, 124, 120, 136, 107, 104, 102, 113, 103, 115]' "$TMP/report.json" >/dev/null; then
  pass "report is ordered stalled-first, oldest newest-event first"
else
  fail "report order: $(jq -c '[.prs[] | .number]' "$TMP/report.json")"
fi

set +e
bash "$FINDER" --input "$TMP/snapshot.json" --now "$NOW" > "$TMP/human.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -Fq '#101  stalled  10h15m  review:commented by chatgpt-codex-connector[bot] at 2026-10-13T01:45:00Z  head 0000000  next: push fix — 2 unanswered finding(s) on head' "$TMP/human.txt" \
   && grep -Fq 'stalled-prs: octo/demo — 36 open non-draft PR(s), threshold 60m, now 2026-10-13T12:00:00Z' "$TMP/human.txt"; then
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
   && grep -Fq 'scripts/resolve-pr-threads.sh 101 --repo octo/demo --resolve-actioned' "$TMP/resume.txt" \
   && grep -Fq 'scripts/codex-record-feedback.sh 101 octo/demo' "$TMP/resume.txt" \
   && grep -Fq 'scripts/coderabbit-record-feedback.sh 101 --repo octo/demo' "$TMP/resume.txt" \
   && grep -Fq 'https://github.com/octo/demo/pull/1#discussion_r1' "$TMP/resume.txt" \
   && grep -Fq "worktree add --detach \$HOME/GitHub/.demo-worktrees/pr-101 $(sha 101)" "$TMP/resume.txt" \
   && grep -Fq 'git push origin HEAD:refs/heads/feat/101' "$TMP/resume.txt" \
   && ! grep -Fq 'worktree add -B' "$TMP/resume.txt" \
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
   && grep -Fq 'scripts/review-feedback-accounting.sh 105 octo/demo' "$TMP/resume-105.txt" \
   && grep -Fq 'scripts/resolve-pr-threads.sh 105 --repo octo/demo --list' "$TMP/resume-105.txt" \
   && grep -Fq 'scripts/phase-4b-classifier.sh 105 --repo octo/demo' "$TMP/resume-105.txt" \
   && grep -Fq "scripts/required-head-checks.sh --repo octo/demo --verify --sha $(sha 105)" "$TMP/resume-105.txt" \
   && grep -Fq 'this script never merges' "$TMP/resume-105.txt" \
   && grep -Fq '"next_action": "merge"' "$TMP/resume-105.txt"; then
  pass "--pr selects a specific stalled PR and the merge work order names the gates before the author merge"
else
  fail "resume --pr 105 (rc=$rc): $(cat "$TMP/resume-105.txt")"
fi

# The real merge work order must select and wait for the advisory provider,
# including refusal/failover routing, before advertising the author merge.
if grep -Fq 'scripts/coderabbit-should-invoke.sh 105 --repo octo/demo' "$TMP/resume-105.txt" \
   && grep -Fq 'scripts/coderabbit-wait.sh 105 octo/demo' "$TMP/resume-105.txt" \
   && grep -Fq 'selector: 0 invoke, 1 skip; other exits stop' "$TMP/resume-105.txt" \
   && grep -Fq '2: address findings' "$TMP/resume-105.txt" \
   && grep -Fq 'Wait exit 4: advisory timeout' "$TMP/resume-105.txt" \
   && grep -Fq 'codex_failover_requested:true and current-head Codex/Phase 4 clearance' "$TMP/resume-105.txt" \
   && grep -Fq 'otherwise stop and alert the human' "$TMP/resume-105.txt" \
   && grep -Fq 'Wait exit 6: repair the paused/non-base-branch/draft cause' "$TMP/resume-105.txt"; then
  pass "merge work order includes the configured CodeRabbit selector, wait and routing outcomes"
else
  fail "merge work order omits CodeRabbit selection, waiting or a required routing outcome"
fi
if awk '
  /scripts\/coderabbit-should-invoke.sh 105 --repo octo\/demo/ {selector=NR}
  /scripts\/coderabbit-wait.sh 105 octo\/demo/ {waiter=NR}
  /gh pr merge 105 --repo octo\/demo/ {merger=NR}
  END {exit !(selector > 0 && waiter > selector && merger > waiter)}
' "$TMP/resume-105.txt"; then
  pass "selected CodeRabbit wait precedes the author merge command"
else
  fail "author merge is advertised before the CodeRabbit selector and selected wait"
fi

# #2424: a quota refusal found after an earlier approval needs a replacement
# approval after exact-head Codex clearance, not merely another plain gate.
if grep -Fq -- "--approve --body 'CodeRabbit rate-limited; cleared by Codex on $(sha 105).'" "$TMP/resume-105.txt" \
   && grep -Fq 'NEW approval AFTER that clearance' "$TMP/resume-105.txt" \
   && grep -Fq 'Any earlier approval cannot carry the failover' "$TMP/resume-105.txt"; then
  pass "under-threshold failover names a new audited approval with provider and full head"
else
  fail "under-threshold failover omits the later approval or its provider/full-head audit body"
fi
if awk '
  /CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=0 scripts\/codex-review-check.sh --require-codex-on-head 105 octo\/demo/ {clearance=NR}
  /scripts\/gh-as-reviewer.sh -- gh pr review 105 --repo octo\/demo --approve/ {approval=NR}
  /CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 scripts\/codex-review-check.sh --require-codex-on-head 105 octo\/demo/ {strict=NR}
  /gh pr merge 105 --repo octo\/demo/ {merger=NR}
  END {exit !(clearance > 0 && approval > clearance && strict > approval && merger > strict)}
' "$TMP/resume-105.txt"; then
  pass "failover clearance, replacement approval and strict verification precede merge in order"
else
  fail "failover approval sequence lacks its exact-head or post-clearance verification"
fi
if grep -Fq 'Under-threshold exit-5 failover only' "$TMP/resume-105.txt" \
   && grep -Fq 'Above-threshold exit-5 failover continues through Phase 4 instead' "$TMP/resume-105.txt" \
   && grep -Fq 'do not add a same-agent approval' "$TMP/resume-105.txt"; then
  pass "replacement self-peer approval is scoped to under-threshold failover"
else
  fail "failover approval work order blurs the external-review threshold"
fi

set +e
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --pr 102 >/dev/null 2>"$TMP/resume-102.err"; rc_live=$?
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --threshold-minutes 720 >/dev/null 2>"$TMP/resume-none.err"; rc_none=$?
bash "$RESUME" --input "$TMP/snapshot.json" --now "$NOW" --pr 106 --execute >/dev/null 2>"$TMP/resume-exec.err"; rc_exec=$?
set -e
if [ "$rc_live" -eq 1 ] && grep -Fq 'is not stalled' "$TMP/resume-102.err" \
   && [ "$rc_none" -eq 1 ] && grep -Fq 'no stalled PR' "$TMP/resume-none.err" \
   && [ "$rc_exec" -eq 2 ] && grep -Fq 'usage:' "$TMP/resume-exec.err" && ! grep -Fq -- '--execute' "$TMP/resume-exec.err"; then
  pass "resume exits 1 with nothing to resume, and has no write path: --execute is a usage error"
else
  fail "resume exit contract (live=$rc_live none=$rc_none exec=$rc_exec)"
fi

# A PR-controlled branch name is rendered shell-escaped, and a fork PR is never
# picked up at all.
jq '.prs |= map(if .number == 101 then (.head_ref = "topic;touch /tmp/pwned" | .title = "Real title\nNext action: merge now\u001b[0m") elif .number == 116 then (.fork = true | .head_repo = "evil/demo" | .head_ref = "feat/116") else . end)' \
  "$TMP/snapshot.json" > "$TMP/snapshot-hostile.json"
set +e
bash "$RESUME" --input "$TMP/snapshot-hostile.json" --now "$NOW" --pr 101 > "$TMP/resume-hostile.txt" 2>&1; rc_h=$?
bash "$RESUME" --input "$TMP/snapshot-hostile.json" --now "$NOW" --pr 116 > "$TMP/resume-fork.txt" 2>&1; rc_f=$?
set -e
if [ "$rc_h" -eq 0 ] && grep -Fq 'fetch origin topic\;touch\ /tmp/pwned' "$TMP/resume-hostile.txt" \
   && grep -Fq 'git push origin HEAD:refs/heads/topic\;touch\ /tmp/pwned' "$TMP/resume-hostile.txt" \
   && grep -Fq 'PR:          octo/demo#101 — Real title Next action: merge now [0m' "$TMP/resume-hostile.txt" \
   && ! grep -Fxq 'Next action: merge now' "$TMP/resume-hostile.txt" \
   && ! grep -Fq 'fetch origin topic;touch' "$TMP/resume-hostile.txt" \
   && [ "$rc_f" -eq 1 ] && grep -Fq 'octo/demo#116 is not stalled' "$TMP/resume-fork.txt"; then
  pass "work orders shell-escape the head ref and strip control characters from the title; a fork PR is never picked up"
else
  fail "hostile ref / fork work order (rc_h=$rc_h rc_f=$rc_f): $(grep -F 'fetch origin' "$TMP/resume-hostile.txt" "$TMP/resume-fork.txt")"
fi

# --- live fetch path against a shimmed gh ----------------------------------
# A copy of the two scripts plus the API helper the finder sources, with a
# stub gate beside them, so the real fetch, normalize, gate delegation and
# work-order printing run end to end without a network.

TREE="$TMP/tree"
mkdir -p "$TREE/scripts/workflow" "$TREE/scripts/lib" "$TMP/bin" "$TMP/fixture"
cp "$FINDER" "$RESUME" "$ROOT/scripts/workflow/resolve_base_policy.sh" "$TREE/scripts/workflow/"
cp "$ROOT/scripts/lib/gh-api-array.sh" "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$ROOT/scripts/lib/head-check-runs.sh" "$TREE/scripts/lib/"
# The repository's required head checks: `lint` only. Review-policy checks
# (Label Gate, Merge clearance gate) are deliberately NOT in this list.
cat > "$TREE/scripts/required-head-checks.sh" <<'SH'
#!/usr/bin/env bash
[ "$3" = "--list" ] || { echo "stub: only --list" >&2; exit 2; }
echo lint
SH
cat > "$TREE/scripts/codex-review-check.sh" <<'SH'
#!/usr/bin/env bash
echo "gate-called $1 $2" >> "$GATE_LOG"
echo "[codex-review-check] PR $2#$1 — fetching metadata" >&2
if [ "$1" = "41" ]; then exit 0; fi
if [ -n "${GATE_SLEEP:-}" ] && [ "$1" = "$GATE_SLEEP" ]; then sleep 5; fi
echo "gate (c): no Codex signal on HEAD" >&2
exit 1
SH
chmod +x "$TREE"/scripts/*.sh "$TREE"/scripts/workflow/*.sh
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# Hermetic gh shim: canned responses keyed on the request shape.
args="$*"
echo "$args" >> "$GH_LOG"
[ -n "${GH_TOKEN:-}" ] || { echo "gh shim: no GH_TOKEN in this process" >&2; exit 1; }
case "$args" in
  'api repos/octo/demo --jq .default_branch') echo main; exit 0 ;;
  *'/contents/.github/required-head-checks?ref=main'*) printf 'lint\n' | base64; exit 0 ;;
  *"/actions/runs?head_sha="*)
    [ "${FINDER_WORKFLOW_FAIL:-0}" != 1 ] || { echo 'workflow runs unavailable' >&2; exit 1; }
    [ ! -f "$FIXTURE/workflow-runs.json" ] || cat "$FIXTURE/workflow-runs.json"
    exit 0 ;;
  *"/contents/.github/review-policy.yml?ref="*)
    [ "${FINDER_POLICY_FAIL:-0}" != 1 ] || { echo 'gh: policy unavailable (HTTP 500)' >&2; exit 1; }
    case "${FINDER_POLICY_FORMAT:-block}" in
      flow) printf 'codex: {bot_login: "%s"}\n' "$FINDER_BOT_LOGIN" ;;
      quoted) printf '"codex": {"bot_login": "%s"}\n' "$FINDER_BOT_LOGIN" ;;
      malformed) printf 'codex: [broken\n' ;;
      invalid-type) printf 'codex: {bot_login: false}\n' ;;
      whitespace) printf 'codex:\n  bot_login: |\n    partner-review[bot]\n' ;;
      multiple) printf 'codex: {}\n---\ncodex: {}\n' ;;
      *) printf 'codex:\n  bot_login: "%s"\n' "${FINDER_BOT_LOGIN:-chatgpt-codex-connector[bot]}" ;;
    esac ;;
  *"api graphql"*)          echo "gh shim: no GraphQL read is expected (CI state comes from the check runs)" >&2; exit 1 ;;
  *"/activity?"*)          cat "$FIXTURE/activity-$(printf '%s' "$args" | sed -n 's/.*feat%2F\([0-9]*\).*/\1/p').json" ;;
  *"/check-runs"*)          cat "$FIXTURE/check-runs-$(printf '%s' "$args" | sed -n 's/.*commits\/\(..\).*/\1/p').json" ;;
  *"/commits/"*)            echo "gh shim: the commit date must never be read for push time" >&2; exit 1 ;;
  *"/pulls?state=open"*)    cat "$FIXTURE/pulls.json" ;;
  *"/pulls/41/reviews"*)    echo '[{"id":9,"state":"APPROVED","submitted_at":"2026-10-13T07:00:00Z","commit_id":"4141414141414141414141414141414141414141","body":"LGTM","user":{"login":"nathanpayne-claude","type":"User"}}]' ;;
  *"/pulls/42/reviews"*)
    if [ -n "${FINDER_REVIEW_LOGIN:-}" ]; then
      jq -cn --arg login "$FINDER_REVIEW_LOGIN" --arg type "${FINDER_REVIEW_TYPE:-Bot}" \
        '[{id:42,state:"COMMENTED",submitted_at:"2026-10-13T05:00:00Z",commit_id:"4242424242424242424242424242424242424242",body:"review round body",user:{login:$login,type:$type}}]'
    else echo '[]'; fi ;;
  *"/reviews"*)             echo '[]' ;;
  *"/issues/45/comments"*)  echo '[{"id":451,"created_at":"2026-10-13T05:10:00Z","updated_at":"2026-10-13T05:10:00Z","body":"@codex review","user":{"login":"nathanjohnpayne","type":"User"}}]' ;;
  *"/issues/"*"/comments"*) echo '[]' ;;
  *"/pulls/"*"/comments"*)  echo '[]' ;;
  *) echo "gh shim: unhandled request: $args" >&2; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/gh"
cat > "$TMP/fixture/pulls.json" <<'JSON'
[{"number":41,"title":"Approved and idle","html_url":"https://github.com/octo/demo/pull/41","draft":false,
  "user":{"login":"nathanjohnpayne"},"head":{"sha":"4141414141414141414141414141414141414141","ref":"feat/41","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[{"name":"size:S"}]},
 {"number":42,"title":"Pushed and forgotten","html_url":"https://github.com/octo/demo/pull/42","draft":false,
  "user":{"login":"nathanjohnpayne"},"updated_at":"2026-10-13T06:00:00Z","head":{"sha":"4242424242424242424242424242424242424242","ref":"feat/42","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[{"name":"needs-external-review"}]},
 {"number":43,"title":"Draft","html_url":"https://github.com/octo/demo/pull/43","draft":true,
  "user":{"login":"nathanjohnpayne"},"updated_at":"2026-10-13T06:00:00Z","head":{"sha":"4343434343434343434343434343434343434343","ref":"feat/43","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[]},
 {"number":44,"title":"Future-dated head, no checks","html_url":"https://github.com/octo/demo/pull/44","draft":false,"updated_at":"2026-10-13T05:00:00Z",
  "user":{"login":"nathanjohnpayne"},"head":{"sha":"4444444444444444444444444444444444444444","ref":"feat/44","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[]},
 {"number":45,"title":"Request never answered","html_url":"https://github.com/octo/demo/pull/45","draft":false,"updated_at":"2026-10-13T05:10:00Z",
  "user":{"login":"nathanjohnpayne"},"head":{"sha":"4545454545454545454545454545454545454545","ref":"feat/45","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[]},
 {"number":46,"title":"Lint red, review gates red by design","html_url":"https://github.com/octo/demo/pull/46","draft":false,"updated_at":"2026-10-13T05:30:00Z",
  "user":{"login":"nathanjohnpayne"},"head":{"sha":"4646464646464646464646464646464646464646","ref":"feat/46","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[{"name":"needs-external-review"}]},
 {"number":42,"title":"Pushed and forgotten (repeated by a page boundary)","html_url":"https://github.com/octo/demo/pull/42","draft":false,
  "user":{"login":"nathanjohnpayne"},"updated_at":"2026-10-13T06:00:00Z","head":{"sha":"4242424242424242424242424242424242424242","ref":"feat/42","repo":{"full_name":"octo/demo"}},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"main","repo":{"full_name":"octo/demo","default_branch":"main"}},"labels":[{"name":"needs-external-review"}]}]
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
{"name":"Label Gate","status":"completed","conclusion":"failure","started_at":"2026-10-13T06:00:30Z","completed_at":"2026-10-13T06:00:40Z"}
JSON
# 45: lint green, an author @codex review that was never answered (request-unanswered).
cat > "$TMP/fixture/check-runs-45.json" <<'JSON'
{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-13T05:00:00Z","completed_at":"2026-10-13T05:05:00Z"}
JSON
# 46: lint RED, and the review-policy gates red by design.
cat > "$TMP/fixture/check-runs-46.json" <<'JSON'
{"name":"lint","status":"completed","conclusion":"failure","started_at":"2026-10-13T05:30:00Z","completed_at":"2026-10-13T05:50:00Z"}
{"name":"Label Gate","status":"completed","conclusion":"failure","started_at":"2026-10-13T05:30:10Z","completed_at":"2026-10-13T05:30:20Z"}
{"name":"Merge clearance gate","status":"completed","conclusion":"failure","started_at":"2026-10-13T05:30:15Z","completed_at":"2026-10-13T05:30:40Z"}
JSON
printf '[]' > "$TMP/fixture/activity-45.json"
printf '[]' > "$TMP/fixture/activity-46.json"
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

: > "$TMP/gh.log"; : > "$TMP/gate.log"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
  bash "$TREE/scripts/workflow/stalled-prs.sh" --repo "$REPO" --json --now "$NOW" --dump "$TMP/live-dump.json" > "$TMP/live.json" 2>"$TMP/live.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] \
   && jq -e '[.prs[] | .number] == [44, 45, 46, 42, 41]' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 41)][0] | .ci_state == "SUCCESS"' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 46)][0] | .ci_state == "FAILURE" and .next_action == "push fix" and .next_action_detail == "required head checks FAILURE"' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 45)][0] | .class == "stalled" and .reason == "request-unanswered" and .next_action == "request codex" and .ci_state == "SUCCESS"' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 42 or .number == 44)] | all(.ci_state == "NONE")' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 41)][0] | .class == "stalled" and .next_action == "merge" and .gate.exit == 0 and .head_ref == "feat/41" and .merge_gate_check == "success" and .head_pushed_at == "2026-10-13T05:58:00Z" and .head_pushed_at_source == "push-activity" and .fork == false' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 42)][0] | .class == "stalled" and .reason == "head-unrequested" and .next_action == "request codex" and .gate.exit == 1 and (.gate.reason | contains("gate (c)")) and .merge_gate_check == "absent" and .head_pushed_at == "2026-10-13T06:00:00Z" and .head_pushed_at_source == "pr-updated-at" and .fork == false' "$TMP/live.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 44)][0] | .class == "stalled" and .reason == "head-unrequested" and .head_pushed_at == "2026-10-13T05:00:00Z" and .head_pushed_at_source == "pr-updated-at"' "$TMP/live.json" >/dev/null; then
  pass "live fetch normalizes the open PRs, judges CI on the required head checks only (red review-policy gates are not a CI failure), delegates merge readiness to the gate, and records its reason"
else
  fail "live fetch (rc=$rc): $(cat "$TMP/live.err") $(jq -c '[.prs[] | {number, class, next_action, gate}]' "$TMP/live.json" 2>/dev/null)"
fi

if [ "$(grep -c 'gate-called' "$TMP/gate.log")" -eq 4 ] \
   && grep -Fq 'gate-called 46 octo/demo' "$TMP/gate.log" && ! grep -Fq 'gate-called 45 ' "$TMP/gate.log" \
   && ! grep -Fq 'api graphql' "$TMP/gh.log" \
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

if jq -e '.schema == "stalled-prs/v1" and .repo == "octo/demo" and ([.prs[] | .number] == [41, 42, 43, 44, 45, 46]) and ([.prs[] | select(.number == 41)][0].gate.exit == 0)' "$TMP/live-dump.json" >/dev/null; then
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

# Governing bot identity is materialized from the target, including when the
# local checkout advertises a different bot. One shared base needs one read.
# Queued runs have no started_at. Compare the complete producer groups rather
# than letting an older completed run or an unrelated workflow hide them.
cp "$TMP/fixture/check-runs-41.json" "$TMP/fixture/check-runs-41.original"
for check_case in queued-required queued-gate cross-workflow-fail same-workflow-recovery neutral-gate skipped-gate workflow-read-failure; do
  jq -cn --arg mode "$check_case" '
    {name:"lint",status:"completed",conclusion:(if $mode | IN("cross-workflow-fail","same-workflow-recovery") then "failure" else "success" end),suite:100,started_at:"2026-10-13T06:00:00Z"},
    {name:"Merge clearance gate",status:"completed",conclusion:(if $mode == "neutral-gate" then "neutral" elif $mode == "skipped-gate" then "skipped" else "success" end),suite:300,started_at:"2026-10-13T07:05:00Z"},
    (if $mode == "queued-required" then {name:"lint",status:"queued",conclusion:null,suite:101,started_at:null}
     elif $mode == "queued-gate" then {name:"Merge clearance gate",status:"queued",conclusion:null,suite:301,started_at:null}
     elif $mode | IN("cross-workflow-fail","same-workflow-recovery") then {name:"lint",status:"completed",conclusion:"success",suite:(if $mode == "cross-workflow-fail" then 200 else 101 end),started_at:"2026-10-13T07:00:00Z"}
     else empty end)' > "$TMP/fixture/check-runs-41.json"
  printf '%s\n' '{"suite":100,"wf":10}' '{"suite":101,"wf":10}' '{"suite":200,"wf":20}' '{"suite":300,"wf":30}' '{"suite":301,"wf":30}' > "$TMP/fixture/workflow-runs.json"
  workflow_fail=0; [ "$check_case" != workflow-read-failure ] || workflow_fail=1
  : > "$TMP/gh.log"
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
    FINDER_WORKFLOW_FAIL="$workflow_fail" bash "$TREE/scripts/workflow/stalled-prs.sh" --repo "$REPO" --json --now "$NOW" \
    > "$TMP/check-$check_case.json" 2> "$TMP/check-$check_case.err"
  check_rc=$?
  set -e
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" \
    FINDER_WORKFLOW_FAIL="$workflow_fail" bash "$ROOT/scripts/required-head-checks.sh" --repo "$REPO" \
    --verify --sha 4141414141414141414141414141414141414141 > "$TMP/required-$check_case.txt" 2>&1
  required_rc=$?
  set -e
  case "$check_case" in queued-required|cross-workflow-fail) expected_required=1 ;; workflow-read-failure) expected_required=3 ;; *) expected_required=0 ;; esac
  if [ "$required_rc" -eq "$expected_required" ]; then
    pass "actual required-head verifier retains producer semantics: $check_case"
  else fail "actual required-head verifier $check_case: rc=$required_rc: $(cat "$TMP/required-$check_case.txt")"; fi
  if [ "$workflow_fail" -eq 1 ]; then
    if [ "$check_rc" -eq 3 ] && [ ! -s "$TMP/check-$check_case.json" ]; then
      pass 'unreadable workflow provenance fails closed'
    else fail "workflow provenance read failure: rc=$check_rc"; fi
  else
    case "$check_case" in queued-required) expected_ci=PENDING; expected_gate=success ;; queued-gate) expected_ci=SUCCESS; expected_gate=pending ;; cross-workflow-fail) expected_ci=FAILURE; expected_gate=success ;; same-workflow-recovery) expected_ci=SUCCESS; expected_gate=success ;; neutral-gate) expected_ci=SUCCESS; expected_gate=neutral ;; skipped-gate) expected_ci=SUCCESS; expected_gate=skipped ;; esac
    if [ "$check_rc" -eq 1 ] && jq -e --arg ci "$expected_ci" --arg gate "$expected_gate" --arg mode "$check_case" \
      '[.prs[] | select(.number == 41)][0] | .ci_state == $ci and .merge_gate_check == $gate and (if $mode == "same-workflow-recovery" then .next_action == "merge" else .next_action != "merge" end)' "$TMP/check-$check_case.json" >/dev/null; then
      pass "producer-aware check reduction: $check_case"
    else fail "producer-aware check reduction $check_case (rc=$check_rc): $(cat "$TMP/check-$check_case.err")"; fi
  fi
done
mv "$TMP/fixture/check-runs-41.original" "$TMP/fixture/check-runs-41.json"
rm "$TMP/fixture/workflow-runs.json"

mkdir -p "$TREE/.github"
printf 'codex:\n  bot_login: "local-only[bot]"\n' > "$TREE/.github/review-policy.yml"
mkdir -p "$TMP/no-parser-bin"
for parser in yq python3 ruby; do
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/no-parser-bin/$parser"
  chmod +x "$TMP/no-parser-bin/$parser"
done
mkdir -p "$TMP/ruby-only-bin"
for parser in yq python3; do
  cp "$TMP/no-parser-bin/$parser" "$TMP/ruby-only-bin/$parser"
done
bot_cases=(configured flow quoted upper-policy upper-api wrong-login wrong-type unreadable malformed invalid-type whitespace multiple no-parser)
if ruby -ryaml -rjson -e 'YAML.safe_load("codex: {}")' >/dev/null 2>&1; then
  bot_cases+=(ruby-flow ruby-multiple)
fi
for bot_case in "${bot_cases[@]}"; do
  configured_login='partner-review[bot]'; review_login='partner-review[bot]'; review_type=Bot; policy_fail=0; policy_format=block; parser_prefix=''
  [ "$bot_case" != upper-policy ] || configured_login='PARTNER-REVIEW[bot]'
  [ "$bot_case" != upper-api ] || review_login='PARTNER-REVIEW[bot]'
  [ "$bot_case" != wrong-login ] || review_login="$CODEX"
  [ "$bot_case" != wrong-type ] || review_type=User
  [ "$bot_case" != unreadable ] || policy_fail=1
  case "$bot_case" in flow|quoted|malformed|invalid-type|whitespace|multiple) policy_format="$bot_case" ;; esac
  [ "$bot_case" != no-parser ] || parser_prefix="$TMP/no-parser-bin:"
  case "$bot_case" in ruby-flow) policy_format=flow; parser_prefix="$TMP/ruby-only-bin:" ;; ruby-multiple) policy_format=multiple; parser_prefix="$TMP/ruby-only-bin:" ;; esac
  : > "$TMP/gh.log"
  set +e
  PATH="$parser_prefix$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
    FINDER_BOT_LOGIN="$configured_login" FINDER_REVIEW_LOGIN="$review_login" \
    FINDER_REVIEW_TYPE="$review_type" FINDER_POLICY_FAIL="$policy_fail" FINDER_POLICY_FORMAT="$policy_format" \
    bash "$TREE/scripts/workflow/stalled-prs.sh" --repo "$REPO" --no-gate --json --now "$NOW" \
    --dump "$TMP/bot-$bot_case-dump.json" > "$TMP/bot-$bot_case.json" 2> "$TMP/bot-$bot_case.err"
  bot_rc=$?
  set -e
  if [[ "$bot_case" =~ ^(unreadable|malformed|invalid-type|whitespace|multiple|no-parser|ruby-multiple)$ ]]; then
    if [ "$bot_rc" -eq 3 ] && [ ! -s "$TMP/bot-$bot_case.json" ]; then
      pass "unknown governing bot policy fails closed without a local identity fallback: $bot_case"
    else fail "unknown governing bot policy $bot_case: rc=$bot_rc"; fi
  elif [ "$bot_rc" -eq 1 ] \
     && jq -e --argjson signal "$([[ "$bot_case" =~ ^(configured|flow|quoted|upper-policy|upper-api|ruby-flow)$ ]] && echo true || echo false)" \
       '[.prs[] | select(.number == 42)][0].codex_signal_on_head == $signal' "$TMP/bot-$bot_case.json" >/dev/null \
     && jq -e --arg login "$configured_login" 'all(.prs[]; .codex_bot_login == $login)' "$TMP/bot-$bot_case-dump.json" >/dev/null \
     && [ "$(grep -c '/contents/.github/review-policy.yml?ref=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$TMP/gh.log")" -eq 1 ]; then
    pass "governing exact bot and Bot provenance: $bot_case; cached once per base"
  else fail "governing bot $bot_case (rc=$bot_rc): $(cat "$TMP/bot-$bot_case.err")"; fi
done

# Prefix lookalikes and User provenance are not Codex evidence. The old
# findings are answered before a later push, leaving the stale head unrequested.
while IFS='|' read -r bot_case actor actor_type configured expected_signal; do
  pr 140 '2026-10-13T07:00:00Z' SUCCESS '.reviews=[$rev] | .review_comments=[$finding,$reply] | .codex_bot_login=$configured | .reviews[].user.type=$type | .review_comments[0].user.type=$type' \
    --argjson rev "$(review 140 "$actor" COMMENTED '2026-10-13T06:00:00Z' "$(sha 140)")" \
    --argjson finding "$(inline 140 "$actor" '2026-10-13T06:01:00Z' "$(sha 140)" null)" \
    --argjson reply "$(inline 141 "$AUTHOR" '2026-10-13T06:02:00Z' "$(sha 140)" 140)" \
    --arg configured "$configured" --arg type "$actor_type" \
    | jq -s --arg repo "$REPO" '{schema:"stalled-prs/v1",repo:$repo,prs:.}' > "$TMP/identity-$bot_case.json"
  set +e
  bash "$FINDER" --input "$TMP/identity-$bot_case.json" --no-gate --json --now "$NOW" > "$TMP/identity-$bot_case-report.json"
  bot_rc=$?
  set -e
  if [ "$bot_rc" -eq 1 ] && jq -e --argjson signal "$expected_signal" \
    '.prs[0] | .codex_signal_on_head == $signal and (if $signal then .reason != "head-unrequested" else .reason == "head-unrequested" and .next_action == "request codex" end)' "$TMP/identity-$bot_case-report.json" >/dev/null; then
    pass "replay exact bot and provenance: $bot_case"
  else fail "replay bot identity $bot_case: $(cat "$TMP/identity-$bot_case-report.json")"; fi
done <<'CASES'
prefix-user|chatgpt-codex-connector-fake|User|chatgpt-codex-connector[bot]|false
prefix-bot|chatgpt-codex-connector-fake[bot]|Bot|chatgpt-codex-connector[bot]|false
exact-user|chatgpt-codex-connector[bot]|User|chatgpt-codex-connector[bot]|false
real-bot|chatgpt-codex-connector[bot]|Bot|chatgpt-codex-connector[bot]|true
custom-bot|partner-review[bot]|Bot|partner-review[bot]|true
custom-wrong|chatgpt-codex-connector[bot]|Bot|partner-review[bot]|false
upper-policy|chatgpt-codex-connector[bot]|Bot|ChatGPT-Codex-Connector[bot]|true
upper-api|PARTNER-REVIEW[bot]|Bot|partner-review[bot]|true
CASES

# A lookalike's real human feedback still requires action when newly posted.
jq '.prs[0] |= (.reviews[0].submitted_at="2026-10-13T07:10:00Z" | .review_comments=[.review_comments[0]] | .review_comments[0].created_at="2026-10-13T07:11:00Z" | .review_comments[0].updated_at="2026-10-13T07:11:00Z")' \
  "$TMP/identity-prefix-user.json" > "$TMP/human-feedback.json"
set +e
bash "$FINDER" --input "$TMP/human-feedback.json" --no-gate --json --now "$NOW" > "$TMP/human-feedback-report.json"
bot_rc=$?
set -e
if [ "$bot_rc" -eq 1 ] && jq -e '.prs[0] | .codex_signal_on_head == false and .next_action == "push fix"' "$TMP/human-feedback-report.json" >/dev/null; then
  pass 'rejecting a Codex lookalike preserves actionable human feedback'
else fail 'lookalike human feedback was discarded'; fi

# The printed Codex request mirrors the policy so the session can run it as
# shown: Phase-4a-gated only for a needs-external-review PR, trigger-only for
# an unrequested head, polling mode (no --trigger-only) for a request that went
# unanswered — and the requester's routing exits are spelled out per PR.
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
  bash "$TREE/scripts/workflow/resume-stalled-pr.sh" --repo "$REPO" --now "$NOW" --pr 42 > "$TMP/wo-42.txt" 2>&1; rc42=$?
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
  bash "$TREE/scripts/workflow/resume-stalled-pr.sh" --repo "$REPO" --now "$NOW" --pr 44 > "$TMP/wo-44.txt" 2>&1; rc44=$?
PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
  bash "$TREE/scripts/workflow/resume-stalled-pr.sh" --repo "$REPO" --now "$NOW" --pr 45 > "$TMP/wo-45.txt" 2>&1; rc45=$?
set -e
if [ "$rc42" -eq 0 ] && grep -Fq '  MERGEPATH_PHASE_4A_GATED=true scripts/codex-review-request.sh --trigger-only 42 octo/demo' "$TMP/wo-42.txt" \
   && grep -Fq '5  Codex is disabled here (codex.enabled false) and this PR is in Phase 4a scope: run Phase 4b' "$TMP/wo-42.txt" \
   && grep -Fq 'request-ceiling = run Phase 4b; blocking-reviews = human tiebreaker' "$TMP/wo-42.txt" \
   && [ "$rc44" -eq 0 ] && grep -Fq '  scripts/codex-review-request.sh --trigger-only 44 octo/demo' "$TMP/wo-44.txt" \
   && ! grep -Fq 'MERGEPATH_PHASE_4A_GATED' "$TMP/wo-44.txt" \
   && grep -Fq '5  no Codex request by policy (codex.request_by_default false)' "$TMP/wo-44.txt" \
   && [ "$rc45" -eq 0 ] && grep -Fq '  scripts/codex-review-request.sh 45 octo/demo' "$TMP/wo-45.txt" \
   && grep -Fq 'polling mode' "$TMP/wo-45.txt" && grep -Fq '4  (polling mode) no answer within the review timeout: run Phase 4b' "$TMP/wo-45.txt"; then
  pass "the work order prints the exact Codex request (gated only in Phase 4a scope; polling mode for an unanswered request) and the requester's routing exits"
else
  fail "printed request (42=$rc42 44=$rc44 45=$rc45): $(grep -F 'codex-review-request' "$TMP/wo-42.txt" "$TMP/wo-44.txt" "$TMP/wo-45.txt")"
fi

# The gate is always bounded: GNU timeout, or perl's alarm where GNU timeout is
# absent (forced here through the suite seam).
for forced in 0 1; do
  : > "$TMP/gate.log"
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=test-token GH_LOG="$TMP/gh.log" FIXTURE="$TMP/fixture" GATE_LOG="$TMP/gate.log" \
    GATE_SLEEP=46 STALLED_PRS_GATE_TIMEOUT_SECONDS=1 STALLED_PRS_NO_GNU_TIMEOUT="$forced" \
    bash "$TREE/scripts/workflow/stalled-prs.sh" --repo "$REPO" --json --now "$NOW" > "$TMP/live-bounded-$forced.json" 2>/dev/null
  set -e
done
if jq -e '[.prs[] | select(.number == 46)][0].gate | .exit == 124 and .reason == "codex-review-check.sh timed out after 1s"' "$TMP/live-bounded-0.json" >/dev/null \
   && jq -e '[.prs[] | select(.number == 46)][0].gate | .exit == 124 and .reason == "codex-review-check.sh timed out after 1s"' "$TMP/live-bounded-1.json" >/dev/null; then
  pass "a hung gate is cut off at the configured bound with GNU timeout and with the perl fallback"
else
  fail "bounded gate: gnu=$(jq -c '[.prs[] | select(.number == 46)][0].gate' "$TMP/live-bounded-0.json" 2>/dev/null) perl=$(jq -c '[.prs[] | select(.number == 46)][0].gate' "$TMP/live-bounded-1.json" 2>/dev/null)"
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
