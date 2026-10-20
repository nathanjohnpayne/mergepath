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
#                    required head checks are still PENDING.
#   waiting-on-bot   The head is CI-complete and a review request is
#                    outstanding on it (an `@codex review` / `@coderabbitai`
#                    command newer than the head with no verdict after it, or
#                    Codex's Review Summary reports the head Running), or the
#                    newest event is bot activity that is not a verdict.
#   waiting-on-human A human stop is in force: a `human-hold`,
#                    `needs-human-review` or `policy-violation` label, or ANY
#                    comment, review body or inline comment on the PR that
#                    currently carries a handoff marker (`[mergepath-handoff]`,
#                    `<!-- mergepath-handback:` or the `## External Review
#                    Required` heading) — by anyone, posted at any time. Never
#                    picked up. Deliberately conservative: there is no timestamp
#                    comparison, because every rule deciding whether a later
#                    event supersedes a handoff has had an edge that resumed a
#                    PR reserved for a human. A person clears it by removing the
#                    label, or by editing or deleting the handoff comment so it
#                    no longer carries the marker.
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
# Evidence sources, and why:
#   - The head's push time is server-generated, never the commit's own
#     committer date (author-controlled metadata: a future-dated commit would
#     read as perpetually live, a cherry-picked old one as instantly stale).
#     In order: the repository activity API's push entry for the head SHA;
#     else the earliest check-run start on the head; else the PR's server-set
#     updated_at (stable across runs, never earlier than the push). The source
#     is reported as head_pushed_at_source.
#   - Only pull requests an agent can drive are picked up: a fork PR, or one
#     not authored by the configured author identity (`author_identity` in
#     .github/review-policy.yml, default nathanjohnpayne), is classified
#     waiting-on-human — the agent cannot push to a contributor's branch.
#   - Codex evidence (review objects, inline findings, verdict and Review
#     Summary comments) is restricted to the Codex bot login; a CodeRabbit or
#     code-scanning review on the head is a verdict, never a Codex signal.
#   - `merge` is recommended only when the repository's own complete policy
#     agrees: the newest `Merge clearance gate` check run on the head is
#     `success` (that required check encodes the threshold, protected-path,
#     Phase 4 and Phase 4b lanes), or that check does not exist in the repo
#     and scripts/codex-review-check.sh exits 0. The merge itself is never
#     performed here.
#   - A handoff marker anywhere on the PR keeps it waiting-on-human for as
#     long as the marker is there (see waiting-on-human above).
#
# Read-only. Collection uses paginated list GETs, governing-policy contents
# GETs and required-head-checks resolution; the delegated gate is read-only too.
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
# The repository's complete merge policy is encoded in this required check
# (scripts/merge-clearance-gate.sh via merge-clearance-gate.yml); `merge` is
# recommended only when its newest run on the head succeeded.
MERGE_GATE_CHECK_NAME="Merge clearance gate"
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
# in live mode it is assembled below from paginated REST reads. The
# classification never touches the network.

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
  [ -r "$SCRIPT_DIR/lib/gh-api-array.sh" ] || infra "missing helper scripts/lib/gh-api-array.sh"
  # shellcheck source=../lib/gh-api-array.sh
  . "$SCRIPT_DIR/lib/gh-api-array.sh"
  [ -r "$SCRIPT_DIR/lib/feedback-policy-helpers.sh" ] || infra "missing feedback policy reader"
  # shellcheck source=../lib/feedback-policy-helpers.sh
  . "$SCRIPT_DIR/lib/feedback-policy-helpers.sh"
  [ -r "$SCRIPT_DIR/lib/head-check-runs.sh" ] || infra "missing shared check-run reducer"
  # shellcheck source=../lib/head-check-runs.sh
  . "$SCRIPT_DIR/lib/head-check-runs.sh"
  [ -f "$SCRIPT_DIR/workflow/resolve_base_policy.sh" ] || infra "missing governing policy resolver"
  # CI state is judged on the repository's own required head checks (the
  # build/test checks scripts/required-head-checks.sh resolves from the
  # default branch, `lint` by default), never on the aggregate check rollup:
  # the rollup also carries review-policy checks — Label Gate, Merge
  # clearance gate — that fail BY DESIGN until external review clears, so it
  # reads FAILURE on every threshold PR and would route each one to a CI
  # "fix" that does not exist.
  [ -x "$SCRIPT_DIR/required-head-checks.sh" ] || infra "missing scripts/required-head-checks.sh"

  # The configured author identity: the only login whose PRs an agent drives.
  # Read from the local policy file (same key codex-review-check.sh honours);
  # an absent key keeps the fleet default.
  # A missing policy file is the default, not an error: under pipefail an
  # unguarded read of an absent file would abort the run silently.
  AGENT_AUTHOR=""
  if [ -r "$ROOT/.github/review-policy.yml" ]; then
    AGENT_AUTHOR=$(sed -n 's/^author_identity:[[:space:]]*["'"'"']\{0,1\}\([^"'"'"'[:space:]#]*\).*/\1/p' "$ROOT/.github/review-policy.yml" | head -n 1) || AGENT_AUTHOR=""
  fi
  [ -n "$AGENT_AUTHOR" ] || AGENT_AUTHOR="nathanjohnpayne"
  if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$REPO" ] || infra "could not detect the current repo; pass --repo"
  fi
  [[ "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || infra "--repo must be owner/repo; got '$REPO'"
  REQUIRED_CHECKS_JSON=$("$SCRIPT_DIR/required-head-checks.sh" --repo "$REPO" --list | jq -R . | jq -cs '[.[] | select(length > 0)]') \
    || infra "could not resolve the required head checks for $REPO"

  fetch_api_array() { gh_api_array "$1" "$2" || infra "$GH_API_ARRAY_ERROR"; }

  # The check-runs endpoint wraps its list in an object, so gh_api_array's
  # array-stream contract does not fit; same failure discipline (a failed
  # read is a status, never an empty list), applied here.
  fetch_check_rows() {  # <endpoint> <row selector> <label>
    local raw err rc=0
    err=$(mktemp "${TMPDIR:-/tmp}/stalled-prs-cr.XXXXXX") || infra "mktemp failed"
    raw=$(gh api --paginate "$1" --jq "$2" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      infra "failed to fetch $3: $(tr '\n' ' ' < "$err")"
    fi
    rm -f "$err"
    printf '%s\n' "$raw" | jq -s '.' 2>/dev/null || infra "failed to parse $3"
  }

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
    jq -c --argjson n "$number" 'first(.[] | select(.number == $n))' "$WORK/pulls.json" > "$WORK/pr.json"
    head_sha=$(jq -r '.head.sha' "$WORK/pr.json")
    # --repo may name another repository; never borrow this checkout's bot
    # configuration. Materialize the governing base through the shared resolver
    # and cache the scalar per base SHA for PRs targeting the same revision.
    base_sha=$(jq -r '.base.sha // ""' "$WORK/pr.json")
    [[ "$base_sha" =~ ^[0-9a-fA-F]{40}$ ]] || infra "PR #$number has no complete base SHA"
    if [ ! -f "$WORK/bot-$base_sha" ]; then
      policy_path=$(TMPDIR="$WORK" bash "$SCRIPT_DIR/workflow/resolve_base_policy.sh" \
        --repo "$REPO" --base-ref "$(jq -r '.base.ref // ""' "$WORK/pr.json")" \
        --base-sha "$base_sha" --default-branch "$(jq -r '.base.repo.default_branch // ""' "$WORK/pr.json")" \
        --materialize-default 2>"$WORK/policy.err") \
        || infra "PR #$number governing policy unreadable: $(cat "$WORK/policy.err")"
      [ -r "$policy_path" ] || infra "PR #$number materialized policy is unreadable"
      policy_yaml_to_json "$policy_path" >"$WORK/bot-policy.json" \
        || infra "PR #$number governing policy could not be parsed; a supported YAML parser is required"
      codex_login=$(jq -ers '
        if length != 1 then error("expected one policy document") else .[0] end
        | if type != "object" then error("policy must be a mapping") else .codex end
        | if . == null then {} else . end
        | if type != "object" then error("codex must be a mapping") else .bot_login end
        | if . == null or . == "" then "chatgpt-codex-connector[bot]"
          elif type == "string" and (test("[[:space:]]") | not) then .
          else error("bot_login must be a string without whitespace") end
      ' "$WORK/bot-policy.json") \
        || infra "PR #$number configured Codex login unreadable"
      printf '%s\n' "${codex_login:-chatgpt-codex-connector[bot]}" >"$WORK/bot-$base_sha"
    fi
    codex_login=$(cat "$WORK/bot-$base_sha")
    fetch_api_array "repos/$REPO/pulls/$number/reviews?per_page=100" "PR #$number reviews" > "$WORK/reviews.json"
    fetch_api_array "repos/$REPO/issues/$number/comments?per_page=100" "PR #$number issue comments" > "$WORK/issue_comments.json"
    fetch_api_array "repos/$REPO/pulls/$number/comments?per_page=100" "PR #$number inline comments" > "$WORK/review_comments.json"
    fetch_check_rows "repos/$REPO/commits/$head_sha/check-runs?per_page=100" \
      '.check_runs[] | {name, status, conclusion, suite: .check_suite.id, started_at, completed_at}' \
      "PR #$number head check runs" > "$WORK/check_runs.json"
    fetch_check_rows "repos/$REPO/actions/runs?head_sha=$head_sha&per_page=100" \
      '.workflow_runs[] | {suite: .check_suite_id, wf: .workflow_id}' \
      "PR #$number workflow runs" > "$WORK/workflow_runs.json"
    # Push time, server-generated only (see the header). The activity API
    # covers same-repository heads; a fork's push lives in the fork.
    head_pushed_at=""
    head_pushed_at_source=""
    head_ref=$(jq -r '.head.ref // ""' "$WORK/pr.json")
    is_fork=$(jq -r '((.head.repo.full_name // "") != (.base.repo.full_name // ""))' "$WORK/pr.json")
    if [ "$is_fork" = "false" ] && [ -n "$head_ref" ]; then
      fetch_api_array "repos/$REPO/activity?ref=$(jq -rn --arg r "refs/heads/$head_ref" '$r | @uri')&activity_type=push&per_page=100" \
        "PR #$number head push activity" > "$WORK/activity.json"
      head_pushed_at=$(jq -r --arg sha "$head_sha" '[.[] | select(.after == $sha) | .timestamp // empty] | max // ""' "$WORK/activity.json")
      [ -z "$head_pushed_at" ] || head_pushed_at_source="push-activity"
    fi
    if [ -z "$head_pushed_at" ]; then
      head_pushed_at=$(jq -r '[.[] | .started_at // empty] | min // ""' "$WORK/check_runs.json")
      [ -z "$head_pushed_at" ] || head_pushed_at_source="check-run"
    fi
    if [ -z "$head_pushed_at" ]; then
      # Neither source knows this push: the PR's server-set updated_at is a
      # stable value no earlier than the push, so a fresh push is never read
      # as old and an old one is never re-dated to this run's clock.
      head_pushed_at=$(jq -r '.updated_at // ""' "$WORK/pr.json")
      head_pushed_at_source="pr-updated-at"
      [ -n "$head_pushed_at" ] || infra "PR #$number has no push activity, no check run and no updated_at"
    fi
    gate_summary=$(head_check_runs_reduce "$MERGE_GATE_CHECK_NAME" "$WORK/check_runs.json" "$WORK/workflow_runs.json") \
      || infra "could not reduce the merge gate for PR #$number"
    merge_gate_check=$(jq -r '.conclusion' <<<"$gate_summary")
    # Required head checks only, newest completed run per workflow with all
    # in-flight runs retaining pending precedence. A head with no check
    # runs at all is NONE (a repository without CI); a required check that
    # has not reported yet on a head that has other runs is PENDING.
    if jq -e 'length == 0' "$WORK/check_runs.json" >/dev/null; then
      ci_state=NONE
    else
      : > "$WORK/required-summaries.jsonl"
      while IFS= read -r check_name; do
        head_check_runs_reduce "$check_name" "$WORK/check_runs.json" "$WORK/workflow_runs.json" >> "$WORK/required-summaries.jsonl" \
          || infra "could not reduce required check '$check_name' for PR #$number"
      done < <(jq -r '.[]' <<<"$REQUIRED_CHECKS_JSON")
      ci_state=$(jq -sr '
        if any(.state == "failed") then "FAILURE"
        elif any(.state != "green") then "PENDING" else "SUCCESS" end' "$WORK/required-summaries.jsonl") \
        || infra "could not derive the CI state for PR #$number"
    fi
    jq -cn \
      --slurpfile pr "$WORK/pr.json" \
      --slurpfile reviews "$WORK/reviews.json" \
      --slurpfile issue_comments "$WORK/issue_comments.json" \
      --slurpfile review_comments "$WORK/review_comments.json" \
      --arg head_pushed_at "$head_pushed_at" \
      --arg head_pushed_at_source "$head_pushed_at_source" \
      --arg merge_gate_check "$merge_gate_check" \
      --arg codex_bot_login "$codex_login" \
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
        head_repo: ($pr.head.repo.full_name // ""),
        fork: (($pr.head.repo.full_name // "") != ($pr.base.repo.full_name // "")),
        labels: [($pr.labels // [])[] | .name],
        head_pushed_at: $head_pushed_at,
        head_pushed_at_source: $head_pushed_at_source,
        merge_gate_check: $merge_gate_check,
        codex_bot_login: $codex_bot_login,
        ci_state: $ci_state,
        reviews: [$reviews[0][] | {id, state, submitted_at, commit_id, body: (.body // ""),
                                   user: {login: (.user.login // ""), type: (.user.type // "")}}],
        issue_comments: [$issue_comments[0][] | {id, created_at, updated_at, body: (.body // ""),
                                                 user: {login: (.user.login // ""), type: (.user.type // "")}}],
        review_comments: [$review_comments[0][] | {id, created_at, updated_at, commit_id, original_commit_id, in_reply_to_id,
                                                   html_url, body: (.body // ""),
                                                   user: {login: (.user.login // ""), type: (.user.type // "")}}],
        gate: null
      }' >> "$WORK/records.jsonl" || infra "could not assemble the record for PR #$number"
  # Pagination has no snapshot guarantee: a PR that moved between pages
  # appears twice, so the loop input is deduplicated and one object is
  # selected per number.
  done < <(jq -r '[.[] | .number] | unique[]' "$WORK/pulls.json")

  SNAPSHOT=$(jq -cs --arg repo "$REPO" --arg now "$NOW" --arg agent "$AGENT_AUTHOR" \
    '{schema: "stalled-prs/v1", repo: $repo, fetched_at: $now, author_identity: $agent, prs: .}' "$WORK/records.jsonl") \
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
  def is_codex($bot_login): (.user.type // "") == "Bot" and (login | ascii_downcase) == ($bot_login | ascii_downcase);
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

  def classify($now; $threshold_seconds; $agent_author):
    . as $pr
    | $pr.author as $author
    | $pr.head_sha as $head
    | ($pr.codex_bot_login // "chatgpt-codex-connector[bot]") as $codex_login
    | ($pr.head_pushed_at | ts) as $head_ts
    # ---- timeline: one event per record that moves the turn ---------------
    | ([ {kind: "push", side: "author", actor: $author, at: $pr.head_pushed_at} ]
       + [ $pr.reviews[]
           | select((.state // "PENDING") != "PENDING")
           | (actor_class($author)) as $cls
           # A body-less COMMENTED review from a bot is the wrapper GitHub puts
           # around a single inline reply (the CodeRabbit resolve
           # acknowledgement, nathanjohnpayne/mergepath#919) — activity, not
           # a verdict. Real bot rounds carry a body.
           | if $cls == "bot" and (.state == "COMMENTED") and ((.body | norm | gsub("[[:space:]]"; "")) == "") then
               {kind: "bot-review-wrapper", side: "bot-activity", actor: login, at: .submitted_at}
             else
               {kind: ("review:" + (.state | ascii_downcase)),
                side: (if $cls == "author" then "author" else "verdict" end),
                actor: login, at: .submitted_at, state: .state, commit_id: .commit_id,
                codex: (is_codex($codex_login) and .commit_id == $head)}
             end ]
       + [ $pr.issue_comments[]
           | (actor_class($author)) as $cls
           | if (.body | is_handoff) and $cls != "bot" then
               {kind: "handoff", side: "handoff", actor: login, at: .created_at}
             elif $cls == "bot" then
               if is_codex($codex_login) and (.body | is_codex_summary) then
                 ((.body | summary_status) as $st
                  | (.body | summary_commit) as $sc
                  | if $st == "completed" and $sc != "" and ($head | startswith($sc)) then
                      {kind: "codex-summary-completed", side: "verdict", actor: login, at: (.updated_at // .created_at), codex: true}
                    elif $st == "running" and $sc != "" and ($head | startswith($sc)) then
                      {kind: "codex-summary-running", side: "bot-activity", actor: login, at: (.updated_at // .created_at), running: true}
                    else
                      {kind: "codex-summary-stale", side: "bot-activity", actor: login, at: (.updated_at // .created_at)}
                    end)
               elif is_codex($codex_login) and (.body | is_codex_verdict) then
                 {kind: "verdict-comment", side: "verdict", actor: login, at: .created_at,
                  names_head: (.body | norm | contains($head)), codex: (.body | norm | contains($head))}
               elif (.body | is_rate_limited) then
                 {kind: "bot-rate-limited", side: "bot-activity", actor: login, at: .created_at}
               else
                 {kind: "bot-comment", side: "bot-activity", actor: login, at: .created_at}
               end
             elif (.body | is_trigger) then
               {kind: "trigger", side: "author", actor: login, at: .created_at, trigger: true,
                provider: (if (.body | strip_markup | test("@codex[[:space:]]+review"; "i")) then "codex" else "coderabbit" end)}
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
    # A Running summary is superseded by any head-anchored Codex verdict that
    # landed at or after it (a findings review while the mutable summary was
    # never flipped to Completed must not read as "still running").
    | ([ $events[] | select(.running == true) | (.at | ts) as $r
         | select(([ $events[] | select(.codex == true and .side == "verdict") | select((.at | ts) >= $r) ] | length) == 0)
       ] | length > 0) as $summary_running
    # A provider rate limit on this head stands until that provider recovers
    # (its own verdict lands after the notice) or the sanctioned failover (a
    # Codex request posted after it) exists — whether or not the trigger it
    # refused is still outstanding, and whatever else is said meanwhile.
    | ([ $events[] | select(.kind == "bot-rate-limited") | select((.at | ts) >= $head_ts) ] | max_by(.at | ts)) as $last_rate_limit
    | ($last_rate_limit != null
       # Only a recovery by the refusing provider itself (a verdict from the same
       # bot) clears it — an unrelated human or reviewer comment does not.
       and ([ $events[] | select(.side == "verdict" and .actor == $last_rate_limit.actor) | select((.at | ts) > ($last_rate_limit.at | ts)) ] | length) == 0
       and ([ $events[] | select(.trigger == true and .provider == "codex") | select((.at | ts) > ($last_rate_limit.at | ts)) ] | length) == 0
      ) as $rate_limited
    # ---- head evidence --------------------------------------------------------
    | ([ $pr.reviews[] | select(is_codex($codex_login)) | select(.commit_id == $head) ] | length > 0
       or ([ $events[] | select(.kind == "verdict-comment" and .names_head == true) ] | length > 0)
       or ([ $events[] | select(.kind == "codex-summary-completed" or .kind == "codex-summary-running") ] | length > 0)
       or ([ $pr.review_comments[] | select(is_codex($codex_login)) | select(.in_reply_to_id == null)
             | select(.commit_id == $head or .original_commit_id == $head) ] | length > 0)
      ) as $codex_signal_on_head
    | ([ $pr.review_comments[] | select((actor_class($author)) != "author") | select(.in_reply_to_id == null)
         | select(.commit_id == $head or .original_commit_id == $head)
         | .id as $id
         | ((.updated_at // .created_at) | ts) as $revised
         # Fix and rebuttal replies are posted under a registered reviewer
         # identity (nathanpayne-*), not the author login: any non-bot reply
         # answers the finding — but only one posted after the finding was
         # last edited or re-raised.
         | select(([ $pr.review_comments[] | select(.in_reply_to_id == $id)
                     | select((actor_class($author)) != "bot")
                     | select((.created_at | ts) >= $revised) ] | length) == 0)
         | {id, actor: login, url: (.html_url // "")} ]) as $unanswered
    # A change request counts only against THIS head: one anchored to the head
    # commit, or submitted after the head was pushed. A CHANGES_REQUESTED from
    # an older round is answered by the push that followed it.
    | ([ $pr.reviews[] | select((actor_class($author)) != "author") | select((.state // "PENDING") != "PENDING")
         | select((actor_class($author)) != "bot" or ((.body | norm | gsub("[[:space:]]"; "")) != ""))
         | select(.commit_id == $head or ((.submitted_at | ts) >= $head_ts)) ]
       | max_by(.submitted_at | ts)) as $latest_verdict
    | ($latest_verdict.state // null) as $latest_verdict_state
    # Reuse the existing actionable finding/change-request criteria. Only
    # evidence strictly after this push can supersede its CI wait; an older
    # or same-second verdict cannot establish that ordering.
    | (any($pr.review_comments[];
           . as $comment
           | ($unanswered | any(.id == $comment.id))
             and (((.updated_at // .created_at) | ts) > $head_ts))
       or ($latest_verdict_state == "CHANGES_REQUESTED" and $latest_verdict.commit_id == $head
           and (($latest_verdict.submitted_at | ts) > $head_ts))) as $actionable_after_push
    | ($pr.ci_state == "PENDING") as $ci_pending
    | (if $ci_pending and ($actionable_after_push | not) then "ci"
       elif $request_outstanding or $summary_running or $rate_limited then "bot"
       elif $newest.side == "bot-activity" then "bot"
       else null end) as $machine_wait
    # A handoff is in force for as long as ANY comment, review body or inline
    # comment on the PR carries a handoff marker — whoever wrote it, whenever
    # it was posted or edited. No timestamp is compared: there is no later
    # event that clears it, only a person removing the marker.
    | (([ $pr.issue_comments[], $pr.reviews[], $pr.review_comments[] ]
        | map(select(.body | is_handoff)) | length) > 0) as $handoff_in_force
    | ($pr.merge_gate_check // "absent") as $merge_gate_check
    | ($merge_gate_check == "success"
       or ($merge_gate_check == "absent" and $pr.gate != null and $pr.gate.exit == 0)) as $merge_ready
    | ([ $pr.labels[] | select(. as $l | human_labels | index($l)) ]) as $human_stop
    # ---- class --------------------------------------------------------------
    | (if ($human_stop | length) > 0 then {class: "waiting-on-human", reason: ("label " + ($human_stop | join(", ")))}
       elif ($pr.fork // false) then {class: "waiting-on-human", reason: "fork PR: the contributor owns the head"}
       elif $author != $agent_author then {class: "waiting-on-human", reason: ("not agent-authored (" + $author + ")")}
       elif $handoff_in_force then {class: "waiting-on-human", reason: "handoff posted"}
       elif $machine_wait == "ci" then
         (if $age < $threshold_seconds then {class: "waiting-on-ci", reason: "required head checks PENDING"}
          else {class: "stalled", reason: "ci-pending-stale"} end)
       elif $machine_wait == "bot" then
         (if $age < $threshold_seconds then
            {class: "waiting-on-bot", reason: (if $rate_limited then "provider rate-limited; no failover request yet"
                                               elif $request_outstanding then "review request outstanding on head"
                                               elif $summary_running then "Codex reports the head Running"
                                               else "bot activity, no verdict yet" end)}
          elif $rate_limited then {class: "stalled", reason: "rate-limit-stale"}
          else {class: "stalled", reason: "request-unanswered"} end)
       elif $age < $threshold_seconds then {class: "live", reason: "newest event younger than the threshold"}
       elif $newest.side == "verdict" then {class: "stalled", reason: "unanswered-verdict"}
       elif ($codex_signal_on_head | not) then {class: "stalled", reason: "head-unrequested"}
       else {class: "stalled", reason: "idle"} end) as $verdict
    # ---- next action --------------------------------------------------------
    | (if $verdict.class == "waiting-on-human" then {next_action: "wait", detail: $verdict.reason}
       elif $verdict.class == "waiting-on-ci" or $verdict.class == "waiting-on-bot" then {next_action: "wait", detail: $verdict.reason}
       elif $verdict.reason == "ci-pending-stale" then {next_action: "investigate", detail: "required head checks PENDING for longer than the threshold"}
       # A red head is fixed before anything is re-requested on it.
       elif ($pr.ci_state == "FAILURE" or $pr.ci_state == "ERROR") then {next_action: "push fix", detail: ("required head checks " + $pr.ci_state)}
       # A provider rate limit is handled by its own wait (coderabbit-wait.sh
       # parses the window and requests the sanctioned Codex failover itself);
       # an unexplained stall there is for a session to look at, never an
       # automatic Codex request.
       elif $verdict.reason == "rate-limit-stale" then {next_action: "investigate", detail: "provider rate-limit notice outlived the threshold with no failover request; run scripts/coderabbit-wait.sh"}
       elif $verdict.reason == "request-unanswered" then {next_action: "request codex", detail: "review request outlived the threshold with no verdict"}
       elif ($unanswered | length) > 0 then {next_action: "push fix", detail: (($unanswered | length | tostring) + " unanswered finding(s) on head")}
       elif $latest_verdict_state == "CHANGES_REQUESTED" then {next_action: "push fix", detail: "latest verdict requested changes on head"}
       elif $merge_ready then {next_action: "merge", detail: (if $merge_gate_check == "success" then "Merge clearance gate check success on head" else "no Merge clearance gate check in this repo; codex-review-check.sh exit 0 on head" end)}
       elif ($merge_gate_check == "failure" and $pr.gate != null and $pr.gate.exit == 0) then {next_action: "investigate", detail: "codex-review-check.sh exit 0 but the Merge clearance gate check failed on head"}
       elif ($codex_signal_on_head | not) and ($pr.ci_state == "SUCCESS" or $pr.ci_state == "NONE") then
         {next_action: "request codex", detail: (if $pr.ci_state == "NONE" then "no Codex signal on head; no CI on head" else "no Codex signal on head; CI green" end)}
       elif $pr.gate != null then {next_action: "investigate", detail: ("codex-review-check.sh exit " + ($pr.gate.exit | tostring) + ": " + ($pr.gate.reason // ""))}
       else {next_action: "investigate", detail: "gate not run"} end) as $action
    | {
        number: $pr.number, title: $pr.title, url: $pr.url, author: $author,
        head_sha: $head, head_ref: $pr.head_ref, head_repo: ($pr.head_repo // ""), fork: ($pr.fork // false),
        head_pushed_at: $pr.head_pushed_at, head_pushed_at_source: ($pr.head_pushed_at_source // "unknown"),
        ci_state: $pr.ci_state, merge_gate_check: $merge_gate_check, labels: $pr.labels,
        class: $verdict.class, reason: $verdict.reason,
        turn: (if $verdict.class == "waiting-on-human" then "human" elif $machine_wait != null then "machine" else "agent" end),
        newest: {kind: $newest.kind, side: $newest.side, actor: $newest.actor, at: $newest.at, age_seconds: $age},
        next_action: $action.next_action, next_action_detail: $action.detail,
        codex_signal_on_head: $codex_signal_on_head,
        request_outstanding: $request_outstanding,
        rate_limited: $rate_limited,
        unanswered_findings: $unanswered,
        gate: $pr.gate
      };

  def report($now; $threshold_minutes):
    {
      schema: "stalled-prs-report/v1",
      repo: .repo,
      generated_at: $now,
      threshold_minutes: $threshold_minutes,
      prs: ((.author_identity // "nathanjohnpayne") as $agent
            | [ .prs[] | select(.draft != true) | classify($now; $threshold_minutes * 60; $agent) ]
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
      # The gate is always bounded: GNU timeout where present, else perl's
      # alarm (present on macOS by default). With neither, the gate is not
      # run at all — an unbounded gate could hang the scheduled routine
      # before it reaches any later PR — and the PR reports "gate not run".
      # STALLED_PRS_NO_GNU_TIMEOUT=1 forces the perl branch (regression-suite
      # seam: every CI runner has GNU timeout, a default macOS install does not).
      if [ "${STALLED_PRS_NO_GNU_TIMEOUT:-0}" != "1" ] && command -v timeout >/dev/null 2>&1; then
        timeout "$GATE_TIMEOUT" "$GATE" "$number" "$REPO" >/dev/null 2>"$gate_err" || rc=$?
      elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$GATE_TIMEOUT" "$GATE" "$number" "$REPO" >/dev/null 2>"$gate_err" || rc=$?
        [ "$rc" -ne 142 ] || rc=124
      else
        echo "stalled-prs: WARN neither timeout nor perl is available; not running the unbounded gate for PR #$number" >&2
        rm -f "$gate_err"
        continue
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
