#!/usr/bin/env bash
# audit-rebuttal-clearances.sh — the #2852 slice 1 baseline (#2943): count the
# PRs merged in a fixed window that had a required-tier Codex or CodeRabbit
# inline finding whose thread was rebutted and resolved with no later re-read
# by the same reviewer. Under #2852's rule such a finding is answered, not
# cleared; the count sizes the extra review and owner load the rule adds.
#
# METHOD CONSTRAINT: retrospective and read-only. The only gh calls are
# `gh api graphql` queries (the search listing and one read per PR, with
# cursor follow-ups for any connection that has another page). Nothing is
# posted. The window is always explicit (--since/--until), so a run is
# reproducible for the same window while GitHub keeps the records.
#
# Definitions (each reuses an existing reader; none is a second grammar):
#   finding        an inline review thread whose ROOT comment is by the Codex
#                  bot or the CodeRabbit bot (codex.bot_login /
#                  coderabbit.bot_login in the policy file).
#   required tier  the root's tier is in resolve_required_tiers of the policy
#                  file. Codex roots are graded by codex_tier_of; CodeRabbit
#                  roots by coderabbit_tier_of, overridden by
#                  coderabbit_unclassified_tier over coderabbit_finding_scan,
#                  exactly as scripts/coderabbit-severity-gate.sh grades an
#                  inline finding (scripts/lib/feedback-policy-helpers.sh).
#   rebutted       any of three kinds of evidence, the union of the Phase 4b
#                  ledger's rebuttal (scripts/codex-review-ledger.sh) and the
#                  accounting spec's reply polarity
#                  (specs/review_feedback_accounting.md § Resolver disposition
#                  polarity):
#                    tag    a reply, by anyone but the reviewer bot, carrying
#                           `[mergepath-resolve: rebuttal-recorded]`, dated by
#                           the later of its creation and last edit;
#                    down   a thumbs-down on the root from anyone but the bot
#                           (codex-record-feedback.sh's rebutted verdict);
#                    reply  the latest recognized-polarity reply by an agent
#                           author (MERGEPATH_AGENT_AUTHORS, the resolver's
#                           set) is `rebutted`. Polarity is read by the
#                           resolver's own reply_disposition_polarity, loaded
#                           at run time from scripts/resolve-pr-threads.sh,
#                           so the vocabulary cannot drift from the
#                           resolver's. One deliberate difference: the
#                           resolver reads only replies after the thread's
#                           latest non-agent comment, so a reviewer's reply
#                           to a rebuttal discards it; here that reply is the
#                           re-read being measured, so the whole thread is
#                           read and a later "Fixed" reply still wins.
#   resolved       the thread's isResolved is true when the audit reads it.
#   rebuttal time  two datings, both reported:
#                    substantive  the latest reply or thumbs-down evidence,
#                                 falling back to the tag only when there is
#                                 neither (the tag is a generated marker and
#                                 carries no argument for the reviewer);
#                    latest       the latest of all evidence, the way the
#                                 Phase 4b untested-rebuttal stop dates it.
#   re-read        Either bot: its own reply in the same thread after the
#                  rebuttal. Codex, also: a Codex review object, or a Codex
#                  verdict comment (crqe_verdicts), posted after the first
#                  `@codex review` mention (the ledger's request grammar, from
#                  any non-bot account, in a PR comment, review comment or
#                  review body) that is itself later than the rebuttal.
#                  CodeRabbit, also (no request ledger; #2852 design question,
#                  provisional): a CodeRabbit review object with a body after
#                  the rebuttal.
#   re-raised      Codex only: a re-read response that is blocking (a review
#                  whose body or inline roots grade p0 or a required tier).
#                  An affirmative verdict is not blocking; any other verdict
#                  and every in-thread reply is ungraded. CodeRabbit re-reads
#                  are not graded.
#   owner marker   a non-bot PR comment with the #2511 line
#                  `TIEBREAK_REBUTTAL_ACCEPTED=<url>@<40-hex>#<finding-id>`
#                  naming the finding (status owner-marker, not matching).
#                  Its head is not compared: a merged PR has no current head.
#   matching PR    a PR with at least one finding that is required-tier,
#                  rebutted and resolved, with no re-read and no owner
#                  marker (status no-reread). Each such Codex finding also
#                  records whether Codex responded after the rebuttal with no
#                  request asking it to (an automatic review of a later
#                  push), so the count can be read against a looser re-read.
#
# What the method cannot see (stated in the summary as well):
#   - The Codex re-read is a lower bound on the ledger's untested test: any
#     Codex response after a post-rebuttal request counts, even one the
#     ledger would not attribute to that request, so the matching count can
#     only be lower than the ledger's would be.
#   - Review-body findings, PR-level summary findings, GHAS findings and
#     registered-reviewer (Phase 4b adapter) threads are not measured; the
#     last are counted separately as out of scope.
#   - Rebuttal prose outside the resolver's finite vocabulary is not a
#     rebuttal here, and an agent cannot be told apart from the owner typing
#     as the author account.
#   - The policy file is read once at the audited checkout; a tier policy
#     that changed inside the window is not modeled.
#   - Thread state is read now, not at merge time.
#
# Usage:
#   scripts/audit-rebuttal-clearances.sh --since <ISO-8601 Z> --until <ISO-8601 Z>
#       [--repo owner/name] [--out-dir DIR] [--policy FILE]
#       [--max-requests N] [--fetch-only | --analyze-only]
#
#   --since/--until  The window, [since, until), as UTC instants such as
#                    2026-10-11T00:00:00Z. Required: the window is never
#                    implicit.
#   --repo           Repository to audit (default nathanjohnpayne/mergepath).
#   --out-dir        Output dir (default .mergepath/rebuttal-clearance-audit).
#   --policy         Review policy whose tiers, bot logins and reviewers apply
#                    (default .github/review-policy.yml beside this script).
#   --max-requests   GraphQL request ceiling for one fetch (default 1200).
#                    Reaching it stops the fetch with exit 3.
#   --fetch-only     Fetch and persist raw records, skip analysis.
#   --analyze-only   Analyze an existing raw extract offline (no network).
#
# Outputs (under --out-dir):
#   raw/prs.jsonl       the PRs merged in the window (number, merged_at, url)
#   raw/pr-<n>.json     one normalized record per PR, or {pr, error}; holds
#                       comment bodies, so it stays local (.mergepath/ is
#                       gitignored)
#   raw/api.tsv         one line per GraphQL request: label and point cost
#   raw/window.json     the window and repository the extract was taken for
#   findings.jsonl      one body-free record per required-tier finding
#   summary.json        totals, matching PRs, not-measured PRs, API spend
#   summary.md          the same, as Markdown
#
# Exit codes: 0 success · 1 bad args · 2 missing dep / GH_TOKEN ·
#             3 listing failed, the window is too large or the request
#               ceiling was reached · 4 analysis finished but at least one
#               PR could not be measured (listed in summary.json)

set -euo pipefail

__AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read-only, so the reviewer scope is enough when a preflight cache exists.
if [ -z "${GH_TOKEN:-}" ] && [ -r "$__AUDIT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__AUDIT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

if [ -r "$__AUDIT_DIR/lib/gh-retry-helpers.sh" ]; then
  # shellcheck source=lib/gh-retry-helpers.sh
  . "$__AUDIT_DIR/lib/gh-retry-helpers.sh"
else
  with_gh_retry() { "$@"; }
fi

for __lib in feedback-policy-helpers.sh reviewers-helpers.sh codex-request-evidence.sh; do
  if [ ! -r "$__AUDIT_DIR/lib/$__lib" ]; then
    echo "[audit-rebuttal-clearances] ERROR: missing helper: $__AUDIT_DIR/lib/$__lib" >&2
    exit 2
  fi
  # shellcheck source=/dev/null
  . "$__AUDIT_DIR/lib/$__lib"
done

log() { echo "[audit-rebuttal-clearances] $*" >&2; }
die() { local rc=$1; shift; echo "[audit-rebuttal-clearances] ERROR: $*" >&2; exit "$rc"; }

command -v jq >/dev/null 2>&1 || die 2 "jq is required"

# --- the resolver's reply polarity, loaded rather than copied ----------------
# reply_is_fix_claim and reply_disposition_polarity are the finite vocabulary
# specs/review_feedback_accounting.md defines. They live inside
# scripts/resolve-pr-threads.sh, which runs on load, so the two function
# bodies are extracted and evaluated. Each must appear exactly once; anything
# else stops the run rather than silently reading no rebuttal at all.
RESOLVER_SRC="${MERGEPATH_RESOLVER_SRC:-$__AUDIT_DIR/resolve-pr-threads.sh}"
load_reply_polarity() {
  [ -r "$RESOLVER_SRC" ] || die 2 "cannot read $RESOLVER_SRC for the reply-polarity vocabulary"
  local fn n src
  for fn in reply_is_fix_claim reply_disposition_polarity; do
    n=$(grep -c "^${fn}() {\$" "$RESOLVER_SRC" || true)
    [ "$n" = 1 ] || die 2 "$RESOLVER_SRC defines $fn() $n times (expected exactly once)"
    src=$(awk -v h="${fn}() {" '$0 == h {on=1} on {print} on && $0 == "}" {exit}' "$RESOLVER_SRC")
    [ -n "$src" ] || die 2 "could not extract $fn() from $RESOLVER_SRC"
    eval "$src"
  done
  declare -F reply_is_fix_claim >/dev/null && declare -F reply_disposition_polarity >/dev/null \
    || die 2 "the reply-polarity functions did not load from $RESOLVER_SRC"
}
load_reply_polarity

# --- argument parsing ---------------------------------------------------------
REPO="nathanjohnpayne/mergepath"
SINCE=""
UNTIL=""
OUT_DIR=".mergepath/rebuttal-clearance-audit"
POLICY="$__AUDIT_DIR/../.github/review-policy.yml"
MAX_REQUESTS=1200
MODE="full"

usage() { sed -n '/^# Usage:/,/^# Outputs/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
is_instant() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)         [ $# -ge 2 ] && [[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 1 "--repo requires owner/name"; REPO="$2"; shift 2 ;;
    --since)        [ $# -ge 2 ] && is_instant "$2" || die 1 "--since requires an instant like 2026-10-11T00:00:00Z"; SINCE="$2"; shift 2 ;;
    --until)        [ $# -ge 2 ] && is_instant "$2" || die 1 "--until requires an instant like 2026-11-10T00:00:00Z"; UNTIL="$2"; shift 2 ;;
    --out-dir)      [ $# -ge 2 ] && [ -n "$2" ] || die 1 "--out-dir requires a path"; OUT_DIR="$2"; shift 2 ;;
    --policy)       [ $# -ge 2 ] && [ -n "$2" ] || die 1 "--policy requires a path"; POLICY="$2"; shift 2 ;;
    --max-requests) [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]{0,5}$ ]] || die 1 "--max-requests requires a positive integer"; MAX_REQUESTS="$2"; shift 2 ;;
    --fetch-only)   MODE="fetch-only"; shift ;;
    --analyze-only) MODE="analyze-only"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die 1 "unknown argument '$1'" ;;
  esac
done

RAW_DIR="$OUT_DIR/raw"
if [ "$MODE" != "analyze-only" ]; then
  [ -n "$SINCE" ] && [ -n "$UNTIL" ] || die 1 "--since and --until are both required"
  [[ "$SINCE" < "$UNTIL" ]] || die 1 "--since must be earlier than --until"
fi

# --- policy -------------------------------------------------------------------
[ -r "$POLICY" ] || die 1 "policy file $POLICY is unreadable"
tiers_rc=0
REQUIRED_TIERS=$(resolve_required_tiers "$POLICY") || tiers_rc=$?
[ "$tiers_rc" -ne 2 ] || die 1 "feedback_policy in $POLICY is malformed"
REQUIRED_JSON=$(printf '%s\n' "$REQUIRED_TIERS" | jq -Rsc 'split("\n") | map(select(length > 0))')
CODEX_BOT=$(read_policy_block_field codex bot_login "$POLICY")
CODEX_BOT=${CODEX_BOT:-chatgpt-codex-connector[bot]}
CR_BOT=$(read_policy_block_field coderabbit bot_login "$POLICY")
CR_BOT=${CR_BOT:-coderabbitai[bot]}
REVIEWERS_JSON=$(read_available_reviewers "$POLICY" | jq -Rsc 'split("\n") | map(select(length > 0))')
# The agent-author set the resolver's polarity reader uses (same variable,
# same default as scripts/resolve-pr-threads.sh).
AGENTS_JSON=$(printf '%s' "${MERGEPATH_AGENT_AUTHORS:-nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}" \
  | jq -Rc 'split(":") | map(select(length > 0))')

# --- fetch phase --------------------------------------------------------------
COMMENT_FIELDS='databaseId author { __typename login } createdAt lastEditedAt body pullRequestReview { databaseId }'
THREAD_FIELDS="id isResolved path
  root: comments(first: 1) { nodes { databaseId reactions(content: THUMBS_DOWN, first: 20) { pageInfo { hasNextPage } nodes { createdAt user { login } } } } }
  comments(first: 60) { pageInfo { hasNextPage endCursor } nodes { $COMMENT_FIELDS } }"
REVIEW_FIELDS='databaseId author { __typename login } submittedAt body'
ISSUE_COMMENT_FIELDS='databaseId author { __typename login } createdAt lastEditedAt body'

Q_SEARCH='query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    issueCount pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number mergedAt url } } }
  rateLimit { cost remaining } }'
Q_PR="query(\$owner: String!, \$name: String!, \$n: Int!) {
  repository(owner: \$owner, name: \$name) { pullRequest(number: \$n) { number mergedAt
    reviewThreads(first: 50) { pageInfo { hasNextPage endCursor } nodes { $THREAD_FIELDS } }
    reviews(first: 50) { pageInfo { hasNextPage endCursor } nodes { $REVIEW_FIELDS } }
    comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { $ISSUE_COMMENT_FIELDS } } } }
  rateLimit { cost remaining } }"
q_more() { # <connection> <first> <fields>
  printf 'query($owner: String!, $name: String!, $n: Int!, $after: String!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $n) {
    %s(first: %s, after: $after) { pageInfo { hasNextPage endCursor } nodes { %s } } } }
  rateLimit { cost remaining } }' "$1" "$2" "$3"
}
Q_THREAD_COMMENTS="query(\$id: ID!, \$after: String!) {
  node(id: \$id) { ... on PullRequestReviewThread {
    comments(first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { $COMMENT_FIELDS } } } }
  rateLimit { cost remaining } }"

API_LOG=""
CEILING_FLAG=""
# gql <label> <query> [gh -f/-F args...] — one counted GraphQL request. The
# ceiling is checked before the request, so a run never spends past it. gql
# runs inside command substitutions, where `die` would end only the subshell,
# so reaching the ceiling also leaves a flag that fetch_all stops on.
gql() {
  local label=$1 query=$2 out n
  shift 2
  n=$(wc -l <"$API_LOG" | tr -d ' ')
  if [ "$n" -ge "$MAX_REQUESTS" ]; then
    : >"$CEILING_FLAG"
    die 3 "request ceiling $MAX_REQUESTS reached before '$label'; raise --max-requests or narrow the window"
  fi
  out=$(with_gh_retry gh api graphql -f query="$query" "$@") || { printf '%s\t%s\n' "$label" "failed" >>"$API_LOG"; return 1; }
  printf '%s\t%s\n' "$label" "$(printf '%s' "$out" | jq -r '.data.rateLimit.cost // "unknown"' 2>/dev/null || echo unknown)" >>"$API_LOG"
  printf '%s' "$out" | jq -e '(.errors // []) | length == 0' >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

fetch_listing() {
  local q after="" page total=0 count=0
  q="repo:$REPO is:pr is:merged merged:$SINCE..$UNTIL"
  : >"$RAW_DIR/prs.all.jsonl"
  while :; do
    if [ -z "$after" ]; then
      page=$(gql "search" "$Q_SEARCH" -f q="$q") || die 3 "the merged-PR search failed"
    else
      page=$(gql "search" "$Q_SEARCH" -f q="$q" -f after="$after") || die 3 "the merged-PR search failed"
    fi
    total=$(printf '%s' "$page" | jq -er '.data.search.issueCount') || die 3 "the search returned no issueCount"
    [ "$total" -le 1000 ] || die 3 "the window matches $total PRs, over the search API's 1000-result cap; narrow it"
    printf '%s' "$page" | jq -c '.data.search.nodes[] | select(.number != null) | {pr: .number, merged_at: .mergedAt, url}' >>"$RAW_DIR/prs.all.jsonl"
    [ "$(printf '%s' "$page" | jq -r '.data.search.pageInfo.hasNextPage')" = true ] || break
    after=$(printf '%s' "$page" | jq -er '.data.search.pageInfo.endCursor') || die 3 "the search page has no endCursor"
  done
  count=$(jq -s 'unique_by(.pr) | length' "$RAW_DIR/prs.all.jsonl")
  [ "$count" -eq "$total" ] || die 3 "the search listed $count of the $total PRs it counted; the listing is incomplete"
  # The search range is inclusive at both ends; keep [since, until).
  jq -sc --arg s "$SINCE" --arg u "$UNTIL" 'unique_by(.pr) | sort_by(.pr) | .[]
    | select(.merged_at != null and .merged_at >= $s and .merged_at < $u)' "$RAW_DIR/prs.all.jsonl" >"$RAW_DIR/prs.jsonl"
  rm -f "$RAW_DIR/prs.all.jsonl"
  log "window lists $(wc -l <"$RAW_DIR/prs.jsonl" | tr -d ' ') merged PRs ($total before the half-open bound)"
}

# fetch_more <work> <connection> <first> <fields> <cursor> — append the
# remaining pages of one PR connection to <work>/<connection>.json.
fetch_more() {
  local work=$1 conn=$2 first=$3 fields=$4 after=$5 page q
  q=$(q_more "$conn" "$first" "$fields")
  while [ -n "$after" ]; do
    page=$(gql "pr $N $conn" "$q" -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F n="$N" -f after="$after") || return 1
    printf '%s' "$page" | jq -c --arg c "$conn" '.data.repository.pullRequest[$c].nodes' >>"$work/$conn.json" || return 1
    if [ "$(printf '%s' "$page" | jq -r --arg c "$conn" '.data.repository.pullRequest[$c].pageInfo.hasNextPage')" = true ]; then
      after=$(printf '%s' "$page" | jq -er --arg c "$conn" '.data.repository.pullRequest[$c].pageInfo.endCursor') || return 1
    else
      after=""
    fi
  done
}

fetch_pr() { # <pr-number> → writes raw/pr-<n>.json, a record or {pr, error}
  N=$1
  local out="$RAW_DIR/pr-$N.json" work first conn after tid page
  work=$(mktemp -d "${TMPDIR:-/tmp}/audit-rebuttal.XXXXXX")
  record_error() { jq -nc --argjson pr "$N" --arg e "$1" '{pr: $pr, error: $e}' >"$out"; rm -rf "$work"; }
  if ! first=$(gql "pr $N" "$Q_PR" -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F n="$N"); then
    record_error "the PR read failed"; return 0
  fi
  if ! printf '%s' "$first" | jq -e '.data.repository.pullRequest.number' >/dev/null 2>&1; then
    record_error "the PR read returned no pull request"; return 0
  fi
  printf '%s' "$first" | jq -c '.data.repository.pullRequest' >"$work/pr.json"
  for conn in reviewThreads reviews comments; do
    jq -c --arg c "$conn" '.[$c].nodes' "$work/pr.json" >"$work/$conn.json"
    after=$(jq -r --arg c "$conn" 'if .[$c].pageInfo.hasNextPage then .[$c].pageInfo.endCursor else "" end' "$work/pr.json")
    case "$conn" in
      reviewThreads) fetch_more "$work" "$conn" 50 "$THREAD_FIELDS" "$after" || { record_error "a reviewThreads page failed"; return 0; } ;;
      reviews)       fetch_more "$work" "$conn" 50 "$REVIEW_FIELDS" "$after" || { record_error "a reviews page failed"; return 0; } ;;
      comments)      fetch_more "$work" "$conn" 100 "$ISSUE_COMMENT_FIELDS" "$after" || { record_error "a comments page failed"; return 0; } ;;
    esac
  done
  jq -sc 'add // []' "$work/reviewThreads.json" >"$work/threads.all.json"
  # A thread with more than 60 comments: read the rest of that thread.
  while IFS=$'\t' read -r tid after; do
    [ -n "$tid" ] || continue
    : >"$work/thread-more.json"
    while [ -n "$after" ]; do
      page=$(gql "pr $N thread comments" "$Q_THREAD_COMMENTS" -f id="$tid" -f after="$after") \
        || { record_error "a thread comments page failed"; return 0; }
      printf '%s' "$page" | jq -c '.data.node.comments.nodes' >>"$work/thread-more.json"
      after=$(printf '%s' "$page" | jq -r 'if .data.node.comments.pageInfo.hasNextPage then .data.node.comments.pageInfo.endCursor else "" end')
    done
    jq -c --arg id "$tid" --slurpfile more "$work/thread-more.json" '
      map(if .id == $id then .comments.nodes += ($more | add // []) | .comments.pageInfo.hasNextPage = false else . end)' \
      "$work/threads.all.json" >"$work/threads.next.json" && mv "$work/threads.next.json" "$work/threads.all.json"
  done < <(jq -r '.[] | select(.comments.pageInfo.hasNextPage) | [.id, .comments.pageInfo.endCursor] | @tsv' "$work/threads.all.json")
  if ! jq -nc --argjson pr "$N" --slurpfile meta "$work/pr.json" --slurpfile th "$work/threads.all.json" \
      --slurpfile rv "$work/reviews.json" --slurpfile ic "$work/comments.json" '
    def login: if .author == null then "" elif .author.__typename == "Bot" then .author.login + "[bot]" else .author.login end;
    def typ: .author.__typename // "";
    def comment: {id: .databaseId, login: login, type: typ, created_at: .createdAt, edited_at: .lastEditedAt,
                  review_id: (.pullRequestReview.databaseId // null), body: (.body // "")};
    {pr: $pr, merged_at: $meta[0].mergedAt,
     threads: [ $th[0][] | {id, is_resolved: .isResolved, path,
                root_downs: [ (.root.nodes[0].reactions.nodes // [])[] | {login: (.user.login // ""), created_at: .createdAt} ],
                root_downs_truncated: (.root.nodes[0].reactions.pageInfo.hasNextPage // false),
                comments: [ .comments.nodes[] | comment ]} ],
     reviews: [ ($rv | add // [])[] | {id: .databaseId, login: login, type: typ, submitted_at: .submittedAt, body: (.body // "")} ],
     comments: [ ($ic | add // [])[] | {id: .databaseId, login: login, type: typ, created_at: .createdAt, edited_at: .lastEditedAt, body: (.body // "")} ]}' \
      >"$out"; then
    record_error "the PR record did not normalize"; return 0
  fi
  rm -rf "$work"
}

fetch_all() {
  command -v gh >/dev/null 2>&1 || die 2 "gh is required for fetching"
  [ -n "${GH_TOKEN:-}" ] || die 2 "GH_TOKEN is required (a read-only token is enough); run op-preflight or set GH_TOKEN"
  mkdir -p "$RAW_DIR"
  API_LOG="$RAW_DIR/api.tsv"
  CEILING_FLAG="$RAW_DIR/.ceiling-reached"
  : >"$API_LOG"
  rm -f "$RAW_DIR"/pr-*.json "$CEILING_FLAG"
  jq -nc --arg repo "$REPO" --arg s "$SINCE" --arg u "$UNTIL" '{repo: $repo, since: $s, until: $u}' >"$RAW_DIR/window.json"
  fetch_listing
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    fetch_pr "$n"
    [ ! -e "$CEILING_FLAG" ] || die 3 "request ceiling $MAX_REQUESTS reached while reading PR #$n; the extract under $RAW_DIR is partial"
  done < <(jq -r '.pr' "$RAW_DIR/prs.jsonl")
  log "raw extract complete under $RAW_DIR ($(wc -l <"$API_LOG" | tr -d ' ') GraphQL requests)"
}

# --- analysis phase -----------------------------------------------------------
# Per PR: grade every bot root with the shared classifiers (bash), read the
# polarity of every agent reply in a required-tier thread (bash, the
# resolver's own function), then one jq program decides each finding.

grade_root() { # <login> <body> → tier or empty; nonzero on a classifier error
  local login=$1 body=$2 tier scan unclassified
  if [ "$login" = "$CR_BOT" ]; then
    tier=$(coderabbit_tier_of "$body") || return 2
    scan=$(coderabbit_finding_scan "$body") || return 2
    unclassified=$(coderabbit_unclassified_tier "$scan") || return 2
    [ -z "$unclassified" ] || tier=$unclassified
    printf '%s' "$tier"
  else
    codex_tier_of "$body"
  fi
}

ANALYZE_JQ='
def tmax: map(select(type == "string")) | max;
def agent: .login as $l | $agents | index($l) != null;
def marker: (.body // "") | test("\\A\\s*\\[mergepath-resolve:");
def human: (.type != "Bot") and ((.login | endswith("[bot]")) | not) and .login != "" and .login != $codex;
($required + ["p0"] | unique) as $blocking
| def blocking_tier: . as $t | $blocking | index($t) != null;
  $pr[0] as $p
| ($p.threads | map(select((.comments | length) > 0))) as $threads
| [ ($p.comments[] | {at: .created_at, login, type, body}),
    ($threads[] | .comments[] | {at: .created_at, login, type, body}),
    ($p.reviews[] | {at: .submitted_at, login, type, body}) ]
  | map(select(human and ((.body // "") | test("@codex review"; "i")) and .at != null) | .at) as $requests
| ( [ $p.reviews[] | select(.login == $codex and .submitted_at != null) | . as $r
      | {kind: "review", at: .submitted_at,
         blocking: ( (($rvtiers[0][($r.id | tostring)] // []))
                     + [ $threads[] | .comments[0] | select(.login == $codex and .review_id == $r.id)
                         | ($tiers[0][(.id | tostring)] // "") ]
                     | any(.[]; blocking_tier) )} ]
    + [ $verdicts[0][] | {kind: "verdict", at: .created_at, blocking: (if .affirmative then false else null end)} ] ) as $responses
| def rereads($t; $bot; $at):
    if $at == null then []
    else
      [ $t.comments[1:][] | select(.login == $bot and .created_at > $at) | {kind: "thread-reply", at: .created_at, blocking: null} ]
      + if $bot == $codex then
          ([ $requests[] | select(. > $at) ] | min) as $q
          | if $q == null then [] else [ $responses[] | select(.at > $q) ] end
        else
          [ $p.reviews[] | select(.login == $cr and (.body | length) > 0 and .submitted_at != null and .submitted_at > $at)
            | {kind: "review", at: .submitted_at, blocking: null} ]
        end
    end
    | sort_by(.at);
  def status($rebutted; $resolved; $rr; $owner):
    if ($rebutted | not) then "not-rebutted"
    elif ($resolved | not) then "rebutted-unresolved"
    elif ($rr | length) > 0 then (if any($rr[]; .blocking == true) then "reread-reraised" else "reread" end)
    elif $owner then "owner-marker"
    else "no-reread" end;
  # Owner tiebreak markers naming a finding (the #2511 line format). The
  # head it names is not compared with anything: a merged PR has no current
  # head to pin to, so any well-formed non-bot marker counts.
  [ $p.comments[] | select(human) | (.body // "")
    | scan("TIEBREAK_REBUTTAL_ACCEPTED=[^@#\\s]+@[0-9a-f]{40}#([0-9]+)") | .[0] | tonumber ] as $owner_marked
  |
  [ $threads[] | . as $t | $t.comments[0] as $root
    | select($root.login == $codex or $root.login == $cr)
    | ($tiers[0][($root.id | tostring)] // "") as $tier
    | select($required | index($tier) != null)
    | $root.login as $bot
    | [ $t.comments[1:][] | select(.login != $bot and ((.body // "") | test("\\[mergepath-resolve:\\s*rebuttal-recorded\\]")))
        | [.created_at, .edited_at] | tmax ] as $tag
    | [ $t.root_downs[] | select(.login != "" and .login != $bot and .login != ($bot | sub("\\[bot\\]$"; ""))) | .created_at ] as $down
    | (reduce $t.comments[1:][] as $e (null;
         if ($e | agent) and ($e | marker | not) and (($pol[0][($e.id | tostring)] // "") != "")
         then {polarity: $pol[0][($e.id | tostring)], at: $e.created_at} else . end)) as $reply
    | (if $reply != null and $reply.polarity == "rebutted" then [$reply.at] else [] end) as $prose
    | (($prose + $down) | tmax) as $sub
    | (if $sub != null then $sub else ($tag | tmax) end) as $at_sub
    | (($tag + $down + $prose) | tmax) as $at_late
    | ($at_sub != null) as $rebutted
    | rereads($t; $bot; $at_sub) as $rr
    | rereads($t; $bot; $at_late) as $rr_late
    | (($owner_marked | index($root.id)) != null) as $owner
    | status($rebutted; $t.is_resolved; $rr; $owner) as $st
    | {pr: $p.pr, finding: $root.id, thread: $t.id,
       bot: (if $bot == $codex then "codex" else "coderabbit" end), tier: $tier, path: $t.path,
       resolved: $t.is_resolved, rebutted: $rebutted,
       rebuttal_sources: [ (if ($tag | length) > 0 then "tag" else empty end),
                           (if ($down | length) > 0 then "thumbs-down" else empty end),
                           (if ($prose | length) > 0 then "reply" else empty end) ],
       reply_polarity: ($reply.polarity // null),
       rebuttal_at: $at_sub, rebuttal_at_latest: $at_late,
       reread_first: ($rr[0] // null),
       owner_marker: $owner,
       # A no-reread Codex finding that Codex did review again, unasked (an
       # automatic review of a later push): not a re-read under the rule,
       # reported so the count can be read against a looser definition.
       later_unrequested_response: (if $st == "no-reread" and $bot == $codex
                                    then any($responses[]; .at > $at_sub) else null end),
       status: $st,
       status_latest: status($rebutted; $t.is_resolved; $rr_late; $owner)} ]
'

analyze_pr() { # <raw pr file> → findings JSON lines on stdout; nonzero when unmeasurable
  local f=$1 work line id login body tier polarity rc
  work=$(mktemp -d "${TMPDIR:-/tmp}/audit-rebuttal-analyze.XXXXXX")
  # Tiers of every root by a graded bot or a registered reviewer.
  printf '{' >"$work/tiers.json"
  local sep=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.id')
    login=$(printf '%s' "$line" | jq -r '.login')
    body=$(printf '%s' "$line" | jq -r '.body')
    rc=0
    tier=$(grade_root "$login" "$body") || rc=$?
    [ "$rc" -eq 0 ] || { rm -rf "$work"; echo "a $login finding could not be graded"; return 1; }
    printf '%s"%s":%s' "$sep" "$id" "$(jq -nc --arg t "$tier" '$t')" >>"$work/tiers.json"
    sep=","
  done < <(jq -c --arg codex "$CODEX_BOT" --arg cr "$CR_BOT" --argjson rv "$REVIEWERS_JSON" '
      .threads[] | .comments[0] // empty
      | select(.login == $codex or .login == $cr or (.login as $l | $rv | index($l) != null))
      | {id, login, body}' "$f")
  printf '}' >>"$work/tiers.json"
  # Body tiers of every Codex review object.
  printf '{' >"$work/rvtiers.json"
  sep=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.id')
    body=$(printf '%s' "$line" | jq -r '.body')
    printf '%s"%s":%s' "$sep" "$id" "$(codex_tiers_of "$body" | jq -Rsc 'split("\n") | map(select(length > 0))')" >>"$work/rvtiers.json"
    sep=","
  done < <(jq -c --arg codex "$CODEX_BOT" '.reviews[] | select(.login == $codex) | {id, body}' "$f")
  printf '}' >>"$work/rvtiers.json"
  # Polarity of every agent reply in a required-tier graded thread.
  printf '{' >"$work/pol.json"
  sep=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.id')
    body=$(printf '%s' "$line" | jq -r '.body')
    polarity=$(reply_disposition_polarity "$body")
    [ -z "$polarity" ] || { printf '%s"%s":"%s"' "$sep" "$id" "$polarity" >>"$work/pol.json"; sep=","; }
  done < <(jq -c --slurpfile tiers "$work/tiers.json" --argjson required "$REQUIRED_JSON" \
      --arg codex "$CODEX_BOT" --arg cr "$CR_BOT" --argjson agents "$AGENTS_JSON" '
      .threads[] | select((.comments | length) > 0)
      | select(.comments[0].login == $codex or .comments[0].login == $cr)
      | select(($tiers[0][(.comments[0].id | tostring)] // "") as $t | $required | index($t) != null)
      | .comments[1:][] | select(.login as $l | $agents | index($l) != null)
      | select((.body // "") | test("\\A\\s*\\[mergepath-resolve:") | not)
      | {id, body}' "$f")
  printf '}' >>"$work/pol.json"
  # Codex verdict comments, by the shared verdict reader (REST-shaped input).
  jq -c '[.comments[] | {id, user: {login}, body, created_at}]' "$f" >"$work/rest-comments.json" \
    || { rm -rf "$work"; echo "the PR comments could not be read"; return 1; }
  crqe_verdicts "$(cat "$work/rest-comments.json")" "$CODEX_BOT" >"$work/verdicts.json" \
    && jq -e 'type == "array"' "$work/verdicts.json" >/dev/null \
    || { rm -rf "$work"; echo "the Codex verdict reader failed"; return 1; }
  jq -c --slurpfile pr "$f" --slurpfile tiers "$work/tiers.json" --slurpfile rvtiers "$work/rvtiers.json" \
    --slurpfile pol "$work/pol.json" --slurpfile verdicts "$work/verdicts.json" \
    --argjson required "$REQUIRED_JSON" --argjson agents "$AGENTS_JSON" \
    --arg codex "$CODEX_BOT" --arg cr "$CR_BOT" -n "$ANALYZE_JQ | .[]" \
    || { rm -rf "$work"; echo "the finding analysis failed"; return 1; }
  # Required-tier roots by registered reviewers: counted, not measured.
  jq -c --slurpfile tiers "$work/tiers.json" --argjson required "$REQUIRED_JSON" --argjson rv "$REVIEWERS_JSON" '
    .pr as $pr | .threads[] | select((.comments | length) > 0) | .comments[0] as $root
    | select($root.login as $l | $rv | index($l) != null)
    | select(($tiers[0][($root.id | tostring)] // "") as $t | $required | index($t) != null)
    | {pr: $pr, finding: $root.id, thread: .id, bot: "registered-reviewer", reviewer: $root.login,
       tier: $tiers[0][($root.id | tostring)], path, resolved: .is_resolved, status: "out-of-scope"}' "$f" \
    || { rm -rf "$work"; echo "the registered-reviewer count failed"; return 1; }
  rm -rf "$work"
}

analyze() {
  [ -f "$RAW_DIR/prs.jsonl" ] || die 1 "no raw extract at $RAW_DIR/prs.jsonl"
  [ -r "$RAW_DIR/window.json" ] || die 1 "no $RAW_DIR/window.json; the extract does not name its window"
  mkdir -p "$OUT_DIR"
  : >"$OUT_DIR/findings.jsonl"
  : >"$OUT_DIR/not-measured.jsonl"
  local n f reason
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$RAW_DIR/pr-$n.json"
    reason=""
    if [ ! -r "$f" ]; then
      reason="no raw record"
    elif ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      reason="the raw record is not JSON"
    elif jq -e 'has("error")' "$f" >/dev/null; then
      reason=$(jq -r '.error' "$f")
    elif jq -e 'any(.threads[]; .root_downs_truncated)' "$f" >/dev/null; then
      reason="a finding root has more than 20 thumbs-down reactions"
    elif ! jq -e '(.threads | type) == "array" and (.reviews | type) == "array" and (.comments | type) == "array"' "$f" >/dev/null; then
      reason="the raw record is incomplete"
    fi
    if [ -z "$reason" ]; then
      if ! analyze_pr "$f" >"$OUT_DIR/pr.findings.tmp" 2>"$OUT_DIR/pr.err.tmp"; then
        reason=$(cat "$OUT_DIR/pr.findings.tmp" "$OUT_DIR/pr.err.tmp" | tail -n 1)
        reason=${reason:-the analysis failed}
      else
        cat "$OUT_DIR/pr.findings.tmp" >>"$OUT_DIR/findings.jsonl"
      fi
    fi
    if [ -n "$reason" ]; then
      log "WARN: PR #$n not measured: $reason"
      jq -nc --argjson pr "$n" --arg r "$reason" '{pr: $pr, reason: $r}' >>"$OUT_DIR/not-measured.jsonl"
    fi
  done < <(jq -r '.pr' "$RAW_DIR/prs.jsonl")
  rm -f "$OUT_DIR/pr.findings.tmp" "$OUT_DIR/pr.err.tmp"

  local api_requests=0 api_points="unknown" commit
  if [ -r "$RAW_DIR/api.tsv" ]; then
    api_requests=$(wc -l <"$RAW_DIR/api.tsv" | tr -d ' ')
    api_points=$(awk -F'\t' '$2 ~ /^[0-9]+$/ {s += $2; next} {u = 1} END {if (u) print "unknown"; else print s + 0}' "$RAW_DIR/api.tsv")
  fi
  commit=$(git -C "$__AUDIT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  jq -n --slurpfile w "$RAW_DIR/window.json" --slurpfile prs <(jq -s '.' "$RAW_DIR/prs.jsonl") \
    --slurpfile fd <(jq -s '.' "$OUT_DIR/findings.jsonl") --slurpfile nm <(jq -s '.' "$OUT_DIR/not-measured.jsonl") \
    --argjson required "$REQUIRED_JSON" --arg policy "$POLICY" --arg commit "$commit" \
    --arg requests "$api_requests" --arg points "$api_points" '
    $w[0] as $win | $prs[0] as $prs | $fd[0] as $f | $nm[0] as $nm
    | ($f | map(select(.bot != "registered-reviewer"))) as $in
    | def prs_where(c): [ $in[] | select(c) | .pr ] | unique;
      def count_by(k): reduce .[] as $x ({}; .[($x | k)] += 1);
    {repo: $win.repo, window: {since: $win.since, until: $win.until, bounds: "[since, until) on mergedAt, UTC"},
     policy: {file: $policy, required_tiers: $required}, script_commit: $commit,
     api: {graphql_requests: ($requests | tonumber), graphql_points: $points},
     totals: {
       prs_merged_in_window: ($prs | length),
       prs_not_measured: ($nm | length),
       prs_measured: (($prs | length) - ($nm | length)),
       prs_with_required_finding: (prs_where(true) | length),
       prs_with_rebutted_resolved_required_finding: (prs_where(.rebutted and .resolved) | length),
       prs_matching: (prs_where(.status == "no-reread") | length),
       prs_matching_latest_dating: (prs_where(.status_latest == "no-reread") | length),
       prs_with_reraised_rebuttal: (prs_where(.status == "reread-reraised") | length),
       prs_with_owner_marker: (prs_where(.status == "owner-marker") | length),
       prs_matching_with_later_unrequested_review: (prs_where(.status == "no-reread" and .later_unrequested_response == true) | length)},
     findings: {
       required: ($in | length),
       by_bot: ($in | count_by(.bot)),
       by_status: ($in | count_by(.status)),
       by_status_latest_dating: ($in | count_by(.status_latest)),
       matching_by_bot: ($in | map(select(.status == "no-reread")) | count_by(.bot))},
     matching_prs: [ prs_where(.status == "no-reread")[] as $n
                     | {pr: $n, url: ([ $prs[] | select(.pr == $n) | .url ][0]),
                        findings: [ $in[] | select(.pr == $n and .status == "no-reread")
                                    | {finding, bot, tier, path, rebuttal_sources, later_unrequested_response} ]} ],
     matching_prs_latest_dating_only: (prs_where(.status_latest == "no-reread") - prs_where(.status == "no-reread")),
     not_measured: $nm,
     out_of_scope: {registered_reviewer_required_threads: ([ $f[] | select(.bot == "registered-reviewer") ] | length),
                    prs: ([ $f[] | select(.bot == "registered-reviewer") | .pr ] | unique | length)}}' >"$OUT_DIR/summary.json"
  jq -r '
    "# Rebuttal-only clearances: \(.repo)\n",
    "Window: \(.window.since) to \(.window.until) (\(.window.bounds)). Required tiers: \(.policy.required_tiers | join(", ")). Script commit: \(.script_commit). GraphQL requests: \(.api.graphql_requests) (points: \(.api.graphql_points)).\n",
    "| Measure | Count |", "|---|---|",
    (.totals | to_entries[] | "| \(.key) | \(.value) |"),
    "", "Findings by status: \(.findings.by_status | tojson). Latest dating: \(.findings.by_status_latest_dating | tojson).", "",
    "Matching PRs: \(if (.matching_prs | length) == 0 then "none" else ([.matching_prs[] | "#\(.pr)"] | join(", ")) end)",
    "", "Not measured: \(if (.not_measured | length) == 0 then "none" else ([.not_measured[] | "#\(.pr) (\(.reason))"] | join(", ")) end)"
  ' "$OUT_DIR/summary.json" >"$OUT_DIR/summary.md"
  rm -f "$OUT_DIR/not-measured.jsonl"
  log "wrote $OUT_DIR/summary.json and $OUT_DIR/summary.md"
  if [ "$(jq '.totals.prs_not_measured' "$OUT_DIR/summary.json")" -gt 0 ]; then
    log "WARN: $(jq '.totals.prs_not_measured' "$OUT_DIR/summary.json") PR(s) not measured; see summary.json .not_measured"
    return 4
  fi
}

# --- main ---------------------------------------------------------------------
case "$MODE" in
  full)         fetch_all; analyze || exit $? ;;
  fetch-only)   fetch_all ;;
  analyze-only) analyze || exit $? ;;
esac
log "done"
