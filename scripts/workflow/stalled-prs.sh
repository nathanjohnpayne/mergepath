#!/usr/bin/env bash
# scripts/workflow/stalled-prs.sh — read-only stalled pull-request finder
# (nathanjohnpayne/mergepath#2165).
#
# The largest share of pull-request wall-clock in this fleet is time when
# nothing is waiting on a machine: a reviewer bot posts its verdict, no agent
# session is alive to act on it, and the PR sits until the next working
# session opens. This finder lists the open, non-draft pull requests whose
# newest event is an unanswered verdict older than a threshold, together with
# the next action an agent session should take, so a scheduled routine (or a
# human) can pick the oldest one up and continue its round.
#
# Usage:
#   scripts/workflow/stalled-prs.sh [--repo owner/repo] [--threshold-minutes N]
#                                   [--json] [--no-gate] [--dump FILE]
#                                   [--input FILE] [--now ISO8601]
#
#   --repo               Repository to inspect. Default: the current repo via
#                        `gh repo view`.
#   --threshold-minutes  Age of the newest event past which a PR waiting on an
#                        agent counts as stalled (default 60).
#   --json               Emit the classified report as JSON instead of the
#                        human table.
#   --no-gate            Skip running scripts/codex-review-check.sh for the
#                        stalled PRs (faster; `merge` can then never be
#                        recommended, `investigate` is reported instead).
#   --dump FILE          Write the normalized snapshot (the fetched records,
#                        before classification) to FILE. A dump is replayable
#                        through --input, which is how the regression suite
#                        builds its fixtures.
#   --input FILE         Classify a snapshot instead of fetching one. No
#                        network, no token, no gate run: the snapshot's own
#                        `gate` field (or null) is used.
#   --now ISO8601        The instant ages are measured from (default: now, UTC).
#                        Required for reproducible fixture runs.
#
# Classification (one class per PR):
#
#   stalled          The ball is in an agent's court and nothing has happened
#                    for at least the threshold: the newest event is a verdict
#                    (a bot review, a bot verdict comment, a reviewer-identity
#                    review or comment, a human reply) with no push after it;
#                    or the head is CI-complete with no Codex request and no
#                    Codex signal on it; or a machine wait (CI, a requested
#                    review) has outlived the threshold with no answer.
#   live             The ball is in an agent's court and the newest event is
#                    younger than the threshold: a session may be acting on it.
#   waiting-on-ci    The newest event is author-side and the head's check
#                    rollup is still PENDING.
#   waiting-on-bot   The head is CI-complete and a review request is
#                    outstanding on it (an `@codex review` / `@coderabbitai`
#                    command newer than the head with no verdict after it, or
#                    Codex's Review Summary reports the head Running), or the
#                    newest event is bot activity that is not a verdict.
#   waiting-on-human A human stop is in force: a `human-hold`,
#                    `needs-human-review` or `policy-violation` label, or the
#                    newest event is a posted handoff (a comment carrying
#                    `[mergepath-handoff]`, `<!-- mergepath-handback:` or the
#                    `## External Review Required` heading). Never picked up.
#
# Next action, reported for every PR (and the only automation hook):
#
#   push fix         CI is red, the latest verdict requested changes, or the
#                    verdict left findings on the head with no agent reply.
#   merge            scripts/codex-review-check.sh exits 0 on the head. The
#                    merge itself is NEVER performed here; the agent session
#                    still runs accounting and the thread gate first.
#   request codex    The head has no Codex signal and CI is green (or a
#                    request was posted and never answered).
#   investigate      None of the above decides it: the gate's one-line reason
#                    (or the stale machine wait) is reported as the detail.
#   wait             A machine or a human is expected to act next.
#
# Verdict bodies are read with U+00A0 (NBSP) normalized to a space: Codex
# posts NBSP inside some of its comments (`Reviewed commit:` lines included),
# and a byte-exact match would miss the head anchor.
#
# Read-only. The only GitHub calls are GETs (and a read-only GraphQL query for
# the head's check rollup); the gate it delegates to is itself read-only.
#
# Exit codes:
#   0  ran; no stalled PR
#   1  ran; at least one stalled PR
#   2  usage error
#   3  a read failed (API / infrastructure); nothing was decided

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"

REPO=""
THRESHOLD_MINUTES=60
JSON_OUT=0
RUN_GATE=1
DUMP_FILE=""
INPUT_FILE=""
NOW=""

usage() {
  echo "usage: stalled-prs.sh [--repo owner/repo] [--threshold-minutes N] [--json] [--no-gate] [--dump FILE] [--input FILE] [--now ISO8601]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --threshold-minutes) [ "$#" -ge 2 ] || usage; THRESHOLD_MINUTES="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    --no-gate) RUN_GATE=0; shift ;;
    --dump) [ "$#" -ge 2 ] || usage; DUMP_FILE="$2"; shift 2 ;;
    --input) [ "$#" -ge 2 ] || usage; INPUT_FILE="$2"; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; NOW="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

case "$THRESHOLD_MINUTES" in ''|*[!0-9]*) usage ;; esac
THRESHOLD_MINUTES=$((10#$THRESHOLD_MINUTES))
[ "$THRESHOLD_MINUTES" -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "stalled-prs: jq is required" >&2; exit 3; }

if [ -z "$NOW" ]; then
  NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi
[[ "$NOW" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
  echo "stalled-prs: --now must be YYYY-MM-DDTHH:MM:SSZ; got '$NOW'" >&2
  exit 2
}

infra() { echo "stalled-prs: ERROR — $*" >&2; exit 3; }

# --- snapshot ---------------------------------------------------------------
# One JSON document per run. In fixture mode it is read verbatim from --input;
# in live mode it is assembled below from paginated REST reads and one
# read-only GraphQL scalar. The classification never touches the network.

SNAPSHOT=""

if [ -n "$INPUT_FILE" ]; then
  [ -r "$INPUT_FILE" ] || infra "cannot read --input $INPUT_FILE"
  SNAPSHOT=$(jq -c 'if (.schema // "") != "stalled-prs/v1" or (.prs | type) != "array"
                     then error("input is not a stalled-prs/v1 snapshot") else . end' "$INPUT_FILE" 2>&1) \
    || infra "invalid --input snapshot: $SNAPSHOT"
  REPO=$(printf '%s' "$SNAPSHOT" | jq -r '.repo // ""')
  [ -n "$REPO" ] || infra "--input snapshot carries no repo"
else
  command -v gh >/dev/null 2>&1 || infra "gh is required for live collection"
  if [ -r "$SCRIPT_DIR/lib/preflight-helpers.sh" ]; then
    # shellcheck source=../lib/preflight-helpers.sh
    . "$SCRIPT_DIR/lib/preflight-helpers.sh"
    preflight_require_token reviewer || true
  fi
  [ -n "${GH_TOKEN:-}" ] || infra "GH_TOKEN is required for live collection (a read-only token is enough)"
  for lib in gh-api-array.sh gh-api-scalar.sh; do
    [ -r "$SCRIPT_DIR/lib/$lib" ] || infra "missing helper scripts/lib/$lib"
  done
  # shellcheck source=../lib/gh-api-array.sh
  . "$SCRIPT_DIR/lib/gh-api-array.sh"
  # shellcheck source=../lib/gh-api-scalar.sh
  . "$SCRIPT_DIR/lib/gh-api-scalar.sh"

  if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$REPO" ] || infra "could not detect the current repo; pass --repo"
  fi
  [[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || infra "--repo must be owner/repo; got '$REPO'"
  OWNER=${REPO%%/*}
  NAME=${REPO#*/}

  fetch_api_array() { gh_api_array "$1" "$2" || infra "$GH_API_ARRAY_ERROR"; }

  # Large PR histories overflow the exec argument limit when passed as
  # `--argjson` (a long-lived PR carries hundreds of comments), so every
  # per-PR payload goes through a file and jq reads it with --slurpfile.
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/stalled-prs.XXXXXX")" || infra "mktemp failed"
  trap 'rm -rf "$WORK"' EXIT

  # The open-PR list is the only read whose failure is total; every per-PR
  # read that fails is also fatal, because a PR whose timeline could not be
  # read must not be reported as live, idle or anything else (#831 contract:
  # a failed read is a status, never a value).
  fetch_api_array "repos/$REPO/pulls?state=open&per_page=100" "open pull requests" > "$WORK/pulls.json"
  : > "$WORK/records.jsonl"
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    jq -c --argjson n "$number" '.[] | select(.number == $n)' "$WORK/pulls.json" > "$WORK/pr.json"
    head_sha=$(jq -r '.head.sha' "$WORK/pr.json")
    fetch_api_array "repos/$REPO/pulls/$number/reviews?per_page=100" "PR #$number reviews" > "$WORK/reviews.json"
    fetch_api_array "repos/$REPO/issues/$number/comments?per_page=100" "PR #$number issue comments" > "$WORK/issue_comments.json"
    fetch_api_array "repos/$REPO/pulls/$number/comments?per_page=100" "PR #$number inline comments" > "$WORK/review_comments.json"
    head_pushed_at=$(gh_api_scalar --shape timestamp "PR #$number head commit date" \
      "repos/$REPO/commits/$head_sha" --jq '.commit.committer.date') \
      || infra "could not read the head commit date for PR #$number"
    # statusCheckRollup is ONE scalar for the head, so no pagination trap
    # (the per-check list would need a cursor loop; the state does not). A
    # head with no check runs at all has a null rollup, reported as NONE.
    ci_state=$(gh_api_scalar "PR #$number head check rollup" graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}' \
      -F owner="$OWNER" -F name="$NAME" -F number="$number" \
      --jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state // "NONE"') \
      || infra "could not read the check rollup for PR #$number"
    jq -cn \
      --slurpfile pr "$WORK/pr.json" \
      --slurpfile reviews "$WORK/reviews.json" \
      --slurpfile issue_comments "$WORK/issue_comments.json" \
      --slurpfile review_comments "$WORK/review_comments.json" \
      --arg head_pushed_at "$head_pushed_at" \
      --arg ci_state "$ci_state" '
      $pr[0] as $pr
      | {
        number: $pr.number,
        title: ($pr.title // ""),
        url: ($pr.html_url // ""),
        author: ($pr.user.login // ""),
        draft: ($pr.draft // false),
        head_sha: ($pr.head.sha // ""),
        head_ref: ($pr.head.ref // ""),
        labels: [($pr.labels // [])[] | .name],
        head_pushed_at: $head_pushed_at,
        ci_state: $ci_state,
        reviews: [$reviews[0][] | {id, state, submitted_at, commit_id, body: (.body // ""),
                                   user: {login: (.user.login // ""), type: (.user.type // "")}}],
        issue_comments: [$issue_comments[0][] | {id, created_at, updated_at, body: (.body // ""),
                                                 user: {login: (.user.login // ""), type: (.user.type // "")}}],
        review_comments: [$review_comments[0][] | {id, created_at, commit_id, original_commit_id, in_reply_to_id,
                                                   html_url, body: (.body // ""),
                                                   user: {login: (.user.login // ""), type: (.user.type // "")}}],
        gate: null
      }' >> "$WORK/records.jsonl" || infra "could not assemble the record for PR #$number"
  done < <(jq -r '.[] | .number' "$WORK/pulls.json")

  SNAPSHOT=$(jq -cs --arg repo "$REPO" --arg now "$NOW" \
    '{schema: "stalled-prs/v1", repo: $repo, fetched_at: $now, prs: .}' "$WORK/records.jsonl") \
    || infra "could not assemble the snapshot"
fi

# --- classification ---------------------------------------------------------
# Pure jq over the snapshot. Every rule in the header comment is encoded
# here and nowhere else; the gate result is an input, never derived.

CLASSIFY_JQ='
  def nbsp: gsub(" "; " ");
  def norm: (. // "") | nbsp;
  def strip_markup: norm | gsub("[`*_~>]"; "");
  def login: (.user.login // "");
  def is_bot: ((.user.type // "") == "Bot") or (login | endswith("[bot]"));
  def actor_class($author): if is_bot then "bot" elif login == $author then "author" else "human" end;
  def is_trigger:
    (strip_markup | test("@codex[[:space:]]+review"; "i"))
    or (strip_markup | test("@coderabbitai[[:space:]]*,?[[:space:]]*(review|full review|resume|try again)"; "i"));
  def is_handoff:
    norm | (test("\\[mergepath-handoff"; "i")
            or test("<!-- mergepath-handback:")
            or test("(?m)^#+[[:space:]]*External Review Required"));
  def is_codex_summary: norm | test("<!-- codex-pull-request-review-summary -->");
  def summary_row:
    norm | capture("(?m)^\\|[[:space:]]*📝[[:space:]]*\\*\\*Code Review\\*\\*[[:space:]]*\\|[[:space:]]*(?<status>[^|]+)\\|[[:space:]]*`(?<commit>[0-9A-Fa-f]{7,40})`") // null;
  def summary_status:
    (summary_row) as $row
    | if $row == null then null
      elif ($row.status | test("Completed"; "i")) then "completed"
      elif ($row.status | test("Running"; "i")) then "running"
      else "unknown" end;
  def summary_commit: (summary_row // {commit: ""}).commit;
  def is_codex_verdict: norm | test("Reviewed commit:|Codex Review"; "i");
  def is_rate_limited: norm | test("rate limit"; "i");
  def ts: (. // "1970-01-01T00:00:00Z") | fromdateiso8601;
  def human_labels: ["human-hold", "needs-human-review", "policy-violation"];

  def classify($now; $threshold_seconds):
    . as $pr
    | $pr.author as $author
    | $pr.head_sha as $head
    | ($pr.head_pushed_at | ts) as $head_ts
    # ---- timeline: one event per record that moves the turn ---------------
    | ([ {kind: "push", side: "author", actor: $author, at: $pr.head_pushed_at} ]
       + [ $pr.reviews[]
           | select((.state // "PENDING") != "PENDING")
           | (actor_class($author)) as $cls
           | {kind: ("review:" + (.state | ascii_downcase)),
              side: (if $cls == "author" then "author" else "verdict" end),
              actor: login, at: .submitted_at, state: .state, commit_id: .commit_id} ]
       + [ $pr.issue_comments[]
           | (actor_class($author)) as $cls
           | if (.body | is_handoff) and $cls != "bot" then
               {kind: "handoff", side: "handoff", actor: login, at: .created_at}
             elif $cls == "bot" then
               if (.body | is_codex_summary) then
                 ((.body | summary_status) as $st
                  | (.body | summary_commit) as $sc
                  | if $st == "completed" and $sc != "" and ($head | startswith($sc)) then
                      {kind: "codex-summary-completed", side: "verdict", actor: login, at: (.updated_at // .created_at)}
                    elif $st == "running" and $sc != "" and ($head | startswith($sc)) then
                      {kind: "codex-summary-running", side: "bot-activity", actor: login, at: (.updated_at // .created_at), running: true}
                    else
                      {kind: "codex-summary-stale", side: "bot-activity", actor: login, at: (.updated_at // .created_at)}
                    end)
               elif (.body | is_codex_verdict) then
                 {kind: "verdict-comment", side: "verdict", actor: login, at: .created_at,
                  names_head: (.body | norm | contains($head))}
               elif (.body | is_rate_limited) then
                 {kind: "bot-rate-limited", side: "bot-activity", actor: login, at: .created_at}
               else
                 {kind: "bot-comment", side: "bot-activity", actor: login, at: .created_at}
               end
             elif (.body | is_trigger) then
               {kind: "trigger", side: "author", actor: login, at: .created_at, trigger: true}
             elif $cls == "author" then
               {kind: "author-comment", side: "author", actor: login, at: .created_at}
             else
               {kind: "human-comment", side: "verdict", actor: login, at: .created_at}
             end ]
       + [ $pr.review_comments[]
           | (actor_class($author)) as $cls
           | if $cls == "author" then
               {kind: "author-reply", side: "author", actor: login, at: .created_at}
             elif $cls == "bot" then
               # A top-level bot finding is dated by its review object; only a
               # bot REPLY (the CodeRabbit resolve acknowledgement) is its own
               # activity.
               (if .in_reply_to_id != null then
                 {kind: "bot-reply", side: "bot-activity", actor: login, at: .created_at}
                else empty end)
             else
               {kind: "reviewer-reply", side: "verdict", actor: login, at: .created_at}
             end ]
      ) as $events
    | ($events | max_by(.at | ts)) as $newest
    | (($now | ts) - ($newest.at | ts)) as $age
    # ---- machine waits ------------------------------------------------------
    | ([ $events[] | select(.trigger == true) | select((.at | ts) >= $head_ts) ] | max_by(.at | ts)) as $last_trigger
    | ($last_trigger != null
       and ([ $events[] | select(.side == "verdict") | select((.at | ts) > ($last_trigger.at | ts)) ] | length) == 0) as $request_outstanding
    | ([ $events[] | select(.running == true) ] | length > 0) as $summary_running
    | ($pr.ci_state == "PENDING") as $ci_pending
    | (if $ci_pending then "ci"
       elif $request_outstanding or $summary_running then "bot"
       elif $newest.side == "bot-activity" then "bot"
       else null end) as $machine_wait
    # ---- head evidence --------------------------------------------------------
    | ([ $pr.reviews[] | select(is_bot) | select(.commit_id == $head) ] | length > 0
       or ([ $events[] | select(.kind == "verdict-comment" and .names_head == true) ] | length > 0)
       or ([ $events[] | select(.kind == "codex-summary-completed" or .kind == "codex-summary-running") ] | length > 0)
       or ([ $pr.review_comments[] | select(is_bot) | select(.in_reply_to_id == null)
             | select(.commit_id == $head or .original_commit_id == $head) ] | length > 0)
      ) as $codex_signal_on_head
    | ([ $pr.review_comments[] | select((actor_class($author)) != "author") | select(.in_reply_to_id == null)
         | select(.commit_id == $head or .original_commit_id == $head)
         | .id as $id
         | select(([ $pr.review_comments[] | select(.in_reply_to_id == $id)
                     | select((actor_class($author)) == "author") ] | length) == 0)
         | {id, actor: login, url: (.html_url // "")} ]) as $unanswered
    | ([ $pr.reviews[] | select((actor_class($author)) != "author") | select((.state // "PENDING") != "PENDING") ]
       | max_by(.submitted_at | ts) | (.state // null)) as $latest_verdict_state
    | ([ $pr.labels[] | select(. as $l | human_labels | index($l)) ]) as $human_stop
    # ---- class --------------------------------------------------------------
    | (if ($human_stop | length) > 0 then {class: "waiting-on-human", reason: ("label " + ($human_stop | join(", ")))}
       elif $newest.side == "handoff" then {class: "waiting-on-human", reason: "handoff posted"}
       elif $machine_wait == "ci" then
         (if $age < $threshold_seconds then {class: "waiting-on-ci", reason: "head check rollup PENDING"}
          else {class: "stalled", reason: "ci-pending-stale"} end)
       elif $machine_wait == "bot" then
         (if $age < $threshold_seconds then
            {class: "waiting-on-bot", reason: (if $request_outstanding then "review request outstanding on head"
                                               elif $summary_running then "Codex reports the head Running"
                                               else "bot activity, no verdict yet" end)}
          else {class: "stalled", reason: "request-unanswered"} end)
       elif $age < $threshold_seconds then {class: "live", reason: "newest event younger than the threshold"}
       elif $newest.side == "verdict" then {class: "stalled", reason: "unanswered-verdict"}
       elif ($codex_signal_on_head | not) then {class: "stalled", reason: "head-unrequested"}
       else {class: "stalled", reason: "idle"} end) as $verdict
    # ---- next action --------------------------------------------------------
    | (if $verdict.class == "waiting-on-human" then {next_action: "wait", detail: $verdict.reason}
       elif $verdict.class == "waiting-on-ci" or $verdict.class == "waiting-on-bot" then {next_action: "wait", detail: $verdict.reason}
       elif $verdict.reason == "ci-pending-stale" then {next_action: "investigate", detail: "head check rollup PENDING for longer than the threshold"}
       elif $verdict.reason == "request-unanswered" then {next_action: "request codex", detail: "review request outlived the threshold with no verdict"}
       elif ($pr.ci_state == "FAILURE" or $pr.ci_state == "ERROR") then {next_action: "push fix", detail: ("head check rollup " + $pr.ci_state)}
       elif ($unanswered | length) > 0 then {next_action: "push fix", detail: (($unanswered | length | tostring) + " unanswered finding(s) on head")}
       elif $latest_verdict_state == "CHANGES_REQUESTED" then {next_action: "push fix", detail: "latest verdict requested changes"}
       elif ($pr.gate != null and $pr.gate.exit == 0) then {next_action: "merge", detail: "codex-review-check.sh exit 0 on head"}
       elif ($codex_signal_on_head | not) and $pr.ci_state == "SUCCESS" then {next_action: "request codex", detail: "no Codex signal on head; CI green"}
       elif $pr.gate != null then {next_action: "investigate", detail: ("codex-review-check.sh exit " + ($pr.gate.exit | tostring) + ": " + ($pr.gate.reason // ""))}
       else {next_action: "investigate", detail: "gate not run"} end) as $action
    | {
        number: $pr.number, title: $pr.title, url: $pr.url, author: $author,
        head_sha: $head, head_ref: $pr.head_ref, ci_state: $pr.ci_state, labels: $pr.labels,
        class: $verdict.class, reason: $verdict.reason,
        turn: (if $verdict.class == "waiting-on-human" then "human" elif $machine_wait != null then "machine" else "agent" end),
        newest: {kind: $newest.kind, side: $newest.side, actor: $newest.actor, at: $newest.at, age_seconds: $age},
        next_action: $action.next_action, next_action_detail: $action.detail,
        codex_signal_on_head: $codex_signal_on_head,
        request_outstanding: $request_outstanding,
        unanswered_findings: $unanswered,
        gate: $pr.gate
      };

  def report($now; $threshold_minutes):
    {
      schema: "stalled-prs-report/v1",
      repo: .repo,
      generated_at: $now,
      threshold_minutes: $threshold_minutes,
      prs: ([ .prs[] | select(.draft != true) | classify($now; $threshold_minutes * 60) ]
            | sort_by([(if .class == "stalled" then 0 else 1 end), (.newest.at | ts)]))
    };
'

classify_snapshot() {  # <snapshot-json>
  local out
  if ! out=$(printf '%s' "$1" | jq -c --arg now "$NOW" --argjson thr "$THRESHOLD_MINUTES" \
               "$CLASSIFY_JQ"' report($now; $thr)' 2>&1); then
    infra "classification failed: $(printf '%s' "$out" | tail -n 1)"
  fi
  printf '%s' "$out"
}

REPORT=$(classify_snapshot "$SNAPSHOT")

# --- merge-gate delegation ---------------------------------------------------
# Only live runs consult the gate, and only for PRs that are stalled on an
# agent's turn: that is the one case where "merge" could be the answer, and
# the gate is the repository's own definition of merge-ready (REVIEW_POLICY.md
# § Phase 4a merge gate). It is read-only; its exit and one-line reason are
# recorded on the snapshot and the classification is re-run with them.
if [ -z "$INPUT_FILE" ] && [ "$RUN_GATE" = "1" ]; then
  GATE="$SCRIPT_DIR/codex-review-check.sh"
  GATE_TIMEOUT="${STALLED_PRS_GATE_TIMEOUT_SECONDS:-300}"
  if [ -x "$GATE" ]; then
    while IFS= read -r number; do
      [ -n "$number" ] || continue
      gate_err=$(mktemp "${TMPDIR:-/tmp}/stalled-prs-gate.XXXXXX") || infra "mktemp failed"
      rc=0
      if command -v timeout >/dev/null 2>&1; then
        timeout "$GATE_TIMEOUT" "$GATE" "$number" "$REPO" >/dev/null 2>"$gate_err" || rc=$?
      else
        "$GATE" "$number" "$REPO" >/dev/null 2>"$gate_err" || rc=$?
      fi
      reason=$(grep -v '^\[codex-review-check\]' "$gate_err" | tail -n 1 | tr -d '\r' || true)
      [ -n "$reason" ] || reason=$(tail -n 1 "$gate_err" | tr -d '\r' || true)
      rm -f "$gate_err"
      [ "$rc" -eq 124 ] && reason="codex-review-check.sh timed out after ${GATE_TIMEOUT}s"
      [ "$rc" -ne 0 ] || reason=""
      SNAPSHOT=$(printf '%s' "$SNAPSHOT" | jq -c --argjson n "$number" --argjson rc "$rc" --arg reason "$reason" \
        '.prs |= map(if .number == $n then .gate = {exit: $rc, reason: $reason} else . end)')
    done < <(printf '%s' "$REPORT" | jq -r '.prs[] | select(.class == "stalled" and .turn == "agent") | .number')
    REPORT=$(classify_snapshot "$SNAPSHOT")
  else
    echo "stalled-prs: WARN scripts/codex-review-check.sh not executable here; merge readiness not evaluated" >&2
  fi
fi

# The dump is written AFTER the gate stage so a replay through --input
# reproduces this run's next-action decisions, gate result included.
if [ -n "$DUMP_FILE" ]; then
  printf '%s\n' "$SNAPSHOT" | jq '.' > "$DUMP_FILE" || infra "could not write --dump $DUMP_FILE"
fi

# --- output -----------------------------------------------------------------

STALLED_COUNT=$(printf '%s' "$REPORT" | jq -r '[.prs[] | select(.class == "stalled")] | length')

if [ "$JSON_OUT" = "1" ]; then
  printf '%s' "$REPORT" | jq '.'
else
  printf '%s' "$REPORT" | jq -r '
    def age: if . >= 86400 then ((. / 86400) | floor | tostring) + "d" + (((. % 86400) / 3600) | floor | tostring) + "h"
             elif . >= 3600 then ((. / 3600) | floor | tostring) + "h" + (((. % 3600) / 60) | floor | tostring) + "m"
             else ((. / 60) | floor | tostring) + "m" end;
    "stalled-prs: " + .repo + " — " + (.prs | length | tostring) + " open non-draft PR(s), threshold "
      + (.threshold_minutes | tostring) + "m, now " + .generated_at,
    (.prs[]
      | "#" + (.number | tostring) + "  " + .class + "  " + (.newest.age_seconds | age)
        + "  " + .newest.kind + " by " + .newest.actor + " at " + .newest.at
        + "  head " + (.head_sha[0:7]) + "  next: " + .next_action + " — " + .next_action_detail),
    (if (.prs | length) == 0 then "(no open non-draft pull requests)" else empty end)
  '
fi

[ "$STALLED_COUNT" -eq 0 ]
