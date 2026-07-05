#!/usr/bin/env bash
# audit-review-latency.sh — mine CodeRabbit review latency + phase-4b adapter
# latency from historical records, to retune the review-cycle wait windows
# (#623) that audit-codex-latency.sh does not cover.
#
# audit-codex-latency.sh already measures the Codex App pairs (ack, verdict,
# 👍 clearance, push→auto-review, clearance→gate→merge). This companion adds
# the two distributions #623's retune needs but that study did not mine:
#
#   d. CodeRabbit review latency — for every CodeRabbit review the bot posts,
#      the gap from the reviewed commit's committer date to the review's
#      post time. This is exactly the window scripts/coderabbit-wait.sh polls
#      (it anchors "cleared" on the HEAD committer date and waits for a
#      CodeRabbit review on/after it), so it is the measured basis for
#      coderabbit.max_wait_seconds.
#   a. Phase-4b adapter latency — elapsed_seconds per round from the local
#      phase-4b loop logs (.mergepath/phase-4b-loops/*.jsonl). This is the
#      real end-to-end CLI review time, an independent corroboration of the
#      Codex App verdict latency that anchors codex.review_timeout_seconds.
#
# METHOD CONSTRAINT (from #623): fully retrospective and read-only. The only
# gh calls are `gh api` GETs and `gh repo view`; nothing is posted, and no
# event stream is simulated — every number is a pre-existing GitHub record
# or a locally-recorded loop log.
#
# Latency definitions (mirror how the wait helpers actually measure):
#   cr_review_latency   review.submitted_at − committer_date(review.commit_id),
#                       the earliest REAL (body-bearing) review per commit.
#                       CodeRabbit reviews are COMMENTED objects carrying the
#                       reviewed commit_id, so each pairs unambiguously with the
#                       commit it reviewed (no timeline reconstruction), and the
#                       object is immutable — unlike the PR-level summary
#                       comment, which CodeRabbit posts as an early walkthrough
#                       placeholder and then edits in place, so its timestamps
#                       measure neither review completion nor a stable event.
#                       Rounds where a rate-limit notice intervened between the
#                       commit and the review segment out (rate_limited=true):
#                       those are the coderabbit-wait.sh retry path, not the
#                       max_wait_seconds budget.
#   p4b_adapter_latency .loop.elapsed_seconds for rounds that produced a
#                       verdict (fail-closed aborts — quota/connection — are
#                       reported separately; they are not review latencies).
#
# Usage:
#   scripts/audit-review-latency.sh [--repos owner/a,owner/b] [--since DATE]
#       [--loops-dir DIR] [--out-dir DIR] [--bot-login LOGIN]
#       [--fetch-only | --analyze-only]
#
#   --repos       Comma-separated repos to mine for CodeRabbit (default: the
#                 CodeRabbit-active consumer fleet, below). Read-only.
#   --since       Skip PRs created before this YYYY-MM-DD (bounds API cost).
#   --loops-dir   Phase-4b loop-log dir (default .mergepath/phase-4b-loops).
#   --out-dir     Output dir (default .mergepath/review-latency-audit).
#   --bot-login   CodeRabbit login prefix (default coderabbitai).
#   --fetch-only  Fetch + persist raw records, skip analysis.
#   --analyze-only  Skip fetching; replay an existing events.jsonl (keeps the
#                 published summary recomputable after GitHub ages records
#                 out — same pattern as audit-codex-latency.sh).
#
# Outputs (under --out-dir):
#   raw/*.jsonl    trimmed per-repo CodeRabbit reviews / comments / commits
#   events.jsonl   normalized stream (commit / cr_review / cr_ratelimit / pr /
#                  p4b_round) — no comment/finding bodies, safe to commit
#   pairs.jsonl    one record per measured latency instance
#   summary.md     n / p50 / p90 / p99 / max per distribution and segment
#
# Exit codes: 0 success · 1 bad args · 2 missing dep / GH_TOKEN · 3 API error
#
# Read-only guarantee: only `gh api` GETs and `gh repo view`. No write of any
# kind — posting anywhere would burn rate-limit budget and contaminate the
# very distributions being measured.

set -euo pipefail

__AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- preflight auto-source (#282): read-only ⇒ reviewer scope --------------
if [ -r "$__AUDIT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__AUDIT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

# --- gh retry helper (#324) -------------------------------------------------
if [ -r "$__AUDIT_DIR/lib/gh-retry-helpers.sh" ]; then
  # shellcheck source=lib/gh-retry-helpers.sh
  . "$__AUDIT_DIR/lib/gh-retry-helpers.sh"
else
  with_gh_retry() { "$@"; }
fi

# --- argument parsing -------------------------------------------------------

# Default fleet: ALL EIGHT CodeRabbit-active consumers (the hub, mergepath,
# does not run CodeRabbit auto-review). Every one currently ships
# coderabbit.enabled: true (verified 2026-07-05) and is on the covered-fleet
# list in docs/agents/coderabbit-audit.md, so the full set is the right
# sampling frame for coderabbit-wait.sh's wait window — a 5-repo subset would
# derive p50/p99 from a partial fleet and miss slower reviews in the omitted
# repos (Codex P2 on #688). Keep this in step with the coderabbit-audit.md
# roster if the fleet changes.
REPOS="nathanjohnpayne/swipewatch,nathanjohnpayne/matchline,nathanjohnpayne/nathanpaynedotcom,nathanjohnpayne/overridebroadway,nathanjohnpayne/tadlockpsychiatry,nathanjohnpayne/device-source-of-truth,nathanjohnpayne/friends-and-family-billing,nathanjohnpayne/device-platform-reporting"
SINCE=""
LOOPS_DIR=".mergepath/phase-4b-loops"
OUT_DIR=".mergepath/review-latency-audit"
BOT_LOGIN="coderabbitai"
MODE="full"

usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repos)      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --repos requires a list" >&2; exit 1; }; REPOS="$2"; shift 2 ;;
    --since)      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --since requires YYYY-MM-DD" >&2; exit 1; }; SINCE="$2"; shift 2 ;;
    --loops-dir)  [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --loops-dir requires a path" >&2; exit 1; }; LOOPS_DIR="$2"; shift 2 ;;
    --out-dir)    [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --out-dir requires a path" >&2; exit 1; }; OUT_DIR="$2"; shift 2 ;;
    --bot-login)  [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --bot-login requires a login" >&2; exit 1; }; BOT_LOGIN="$2"; shift 2 ;;
    --fetch-only)   MODE="fetch-only"; shift ;;
    --analyze-only) MODE="analyze-only"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }
log() { echo "[audit-review-latency] $*" >&2; }
RAW_DIR="$OUT_DIR/raw"

api_get() { with_gh_retry gh api --paginate "$@"; }

# --- fetch phase ------------------------------------------------------------

fetch_all() {
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required for fetching" >&2; exit 2; }
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: GH_TOKEN is required (reviewer PAT). Run op-preflight or set GH_TOKEN." >&2
    exit 2
  fi
  mkdir -p "$RAW_DIR"
  : > "$RAW_DIR/reviews.jsonl"
  : > "$RAW_DIR/issue_comments.jsonl"
  : > "$RAW_DIR/commits.jsonl"
  : > "$RAW_DIR/pr_meta.jsonl"

  local repo n
  IFS=',' read -ra __repos <<< "$REPOS"
  for repo in "${__repos[@]}"; do
    [ -n "$repo" ] || continue
    log "fetching PR list for $repo"
    local pulls
    pulls=$(api_get "repos/$repo/pulls?state=all&per_page=100&sort=created&direction=desc" --jq '.[]' \
      | jq -c --arg since "$SINCE" 'select($since == "" or .created_at >= $since)
          | {pr:.number, created_at, head_sha:.head.ref}') \
      || { echo "ERROR: failed fetching PR list for $repo" >&2; exit 3; }

    for n in $(echo "$pulls" | jq -r '.pr'); do
      log "fetching $repo #$n records"
      with_gh_retry gh api "repos/$repo/pulls/$n" \
        | jq -c --arg repo "$repo" '{repo:$repo, pr:.number, created_at, merged_at,
              closed_at, state, additions, head_sha:.head.sha}' \
        >> "$RAW_DIR/pr_meta.jsonl" || { echo "ERROR: $repo #$n meta fetch failed" >&2; exit 3; }

      # CodeRabbit review objects: submitted_at + reviewed commit_id + whether
      # the review carried inline findings (state alone is always COMMENTED).
      api_get "repos/$repo/pulls/$n/reviews?per_page=100" --jq '.[]' \
        | jq -c --arg repo "$repo" --argjson pr "$n" --arg bot "$BOT_LOGIN" '
            select((.user.login // "") | startswith($bot))
            | {repo:$repo, pr:$pr, id, submitted_at, commit_id, state,
               body_len:((.body // "") | length)}' \
        >> "$RAW_DIR/reviews.jsonl" || { echo "ERROR: $repo #$n reviews fetch failed" >&2; exit 3; }

      # CodeRabbit PR-level issue comments (summary/walkthrough + notices).
      # Bodies kept ONLY long enough to classify in normalize(); never emitted
      # to events.jsonl.
      api_get "repos/$repo/issues/$n/comments?per_page=100" --jq '.[]' \
        | jq -c --arg repo "$repo" --argjson pr "$n" --arg bot "$BOT_LOGIN" '
            select((.user.login // "") | startswith($bot))
            | {repo:$repo, pr:$pr, id, created_at, updated_at, body}' \
        >> "$RAW_DIR/issue_comments.jsonl" || { echo "ERROR: $repo #$n comments fetch failed" >&2; exit 3; }

      # Commit committer dates — the anchor for the review-latency measure
      # (review.submitted_at − committer_date(review.commit_id)).
      api_get "repos/$repo/pulls/$n/commits?per_page=100" --jq '.[]' \
        | jq -c --arg repo "$repo" '{repo:$repo, sha, committer_date:.commit.committer.date}' \
        >> "$RAW_DIR/commits.jsonl" || { echo "ERROR: $repo #$n commits fetch failed" >&2; exit 3; }
    done

    # Commit dates for review commit_ids not reachable from the final head
    # (force-pushed-away round heads). Without them a review's anchor is
    # missing and the pair is silently dropped.
    local sha
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      with_gh_retry gh api "repos/$repo/commits/$sha" \
        --jq "{repo:\"$repo\", sha:.sha, committer_date:.commit.committer.date}" 2>/dev/null \
        | jq -c '.' >> "$RAW_DIR/commits.jsonl" \
        || log "WARN: $repo commit $sha not fetchable (deleted branch?) — its review pair is unanchored"
    done < <(
      jq -r --arg repo "$repo" 'select(.repo==$repo and .commit_id != null) | .commit_id' "$RAW_DIR/reviews.jsonl" \
        | sort -u \
        | grep -vxF -f <(jq -r --arg repo "$repo" 'select(.repo==$repo) | .sha' "$RAW_DIR/commits.jsonl" | sort -u) || true
    )
  done
  log "raw extract complete under $RAW_DIR"
}

# --- normalize phase --------------------------------------------------------
# One classification pass. Emits body-free events so events.jsonl is safe to
# commit and replay. CodeRabbit notice classification mirrors
# scripts/coderabbit-wait.sh classify_comment (marker-first, #593).

read_phase4b_rounds() {
  # Emit one p4b_round event per loop record. Reads .loop only — never the
  # .details finding bodies (code-review text stays local). No-op when the
  # dir is absent (e.g. --analyze-only on a clean checkout).
  #
  # Scan BOTH the live *.jsonl logs AND the rotated *.jsonl.archive files:
  # p4b_acct_hook_rotate_loop_log_after_approval appends the consumed loops to
  # <log>.archive and empties the live log once a Phase-4b approval/fallback is
  # posted, so a live-only scan would systematically drop every completed round
  # and bias the a_p4b_adapter_* distribution toward unrotated leftovers
  # (Codex P2 on #688).
  [ -d "$LOOPS_DIR" ] || return 0
  local f
  for f in "$LOOPS_DIR"/*.jsonl "$LOOPS_DIR"/*.jsonl.archive; do
    [ -e "$f" ] || continue
    # jq streams valid records to stdout (→ events.jsonl) as it goes; a
    # malformed/truncated line makes it exit non-zero AFTER the good records
    # and drop the rest. WARN on that instead of swallowing it with `|| true`
    # — a corrupt loop log would otherwise bias the p4b_adapter distribution
    # invisibly (Codex P3 on #688). `2>/dev/null` hides jq's own parse message;
    # we surface our own, which does not pollute the stdout event stream.
    if ! jq -c 'select(.schema=="p4b-loop-log/v1") | .loop
      | {kind:"p4b_round", reviewer, adapter, direction, loop, verdict,
         fell_back, elapsed_seconds, timeout_seconds, effort}' "$f" 2>/dev/null; then
      log "WARN: phase-4b loop log $f is not valid line-delimited JSON (malformed/truncated?) — records after the bad line are omitted from the p4b distribution"
    fi
  done
}

normalize() {
  if [ ! -d "$RAW_DIR" ]; then
    if [ -s "$OUT_DIR/events.jsonl" ]; then
      log "no raw extract at $RAW_DIR — replaying existing events.jsonl"
      return 0
    fi
    echo "ERROR: no raw extract at $RAW_DIR and no $OUT_DIR/events.jsonl to replay" >&2
    exit 1
  fi
  log "normalizing raw records → events.jsonl"
  {
    jq -c '. + {kind:"pr"}' "$RAW_DIR/pr_meta.jsonl"
    jq -c '{kind:"commit", repo, sha, committer_date}' "$RAW_DIR/commits.jsonl"
    # real_review = the review carried a top-level body (the walkthrough /
    # summary CodeRabbit attaches to its actual review). The zero-length
    # COMMENTED objects CodeRabbit emits when it resolves threads or replies
    # to interactions are NOT reviews-of-a-push and must not count as review
    # latency (observed on swipewatch #80: one 5.6 KB review at +689s, then
    # six empty review objects at +1090s from thread resolution).
    jq -c '{kind:"cr_review", repo, pr, review_id:.id, submitted_at, commit_id, state,
            real_review:(.body_len > 0)}' "$RAW_DIR/reviews.jsonl"
    # CodeRabbit rate-limit notices — the ONLY PR-level comment class the
    # analysis needs: it marks rounds where a rate-limit intervened between the
    # commit and the review (those are handled by the coderabbit-wait.sh retry
    # path, not by max_wait_seconds, so they segment out). Marker-first,
    # mirroring coderabbit-wait #593. Review latency itself is measured only
    # from the immutable review OBJECT (cr_review, above), never from the
    # PR-level summary comment: CodeRabbit posts that as an early walkthrough
    # placeholder and then edits it in place, so neither its created_at
    # (placeholder time, ~37s p50) nor its updated_at (edits hours later) is a
    # clean measure of when the review actually landed.
    jq -c '
      def is_ratelimit:
        ((.body // "") | test("rate limited by coderabbit.ai|rate[- ]limit exceeded|review limit reached|fair usage limit|next review available in"; "i"));
      select(is_ratelimit)
      | {kind:"cr_ratelimit", repo, pr, comment_id:.id, created_at}' \
      "$RAW_DIR/issue_comments.jsonl"
    read_phase4b_rounds
  } > "$OUT_DIR/events.jsonl"
}

# --- analysis phase ---------------------------------------------------------

analyze() {
  [ -s "$OUT_DIR/events.jsonl" ] || { echo "ERROR: $OUT_DIR/events.jsonl missing/empty" >&2; exit 1; }
  # Phase-4b rounds can be present even with no CodeRabbit events; guard the
  # pairing but always run the phase-4b extraction.
  log "pairing events → pairs.jsonl"

  jq -cs '
    def ts: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
    def addbucket: if . == null then "unknown"
      elif . <= 50 then "additions<=50" elif . <= 150 then "additions=51-150"
      elif . <= 300 then "additions=151-300" elif . <= 1000 then "additions=301-1000"
      else "additions>1000" end;

    map(select(.kind != null)) as $ev
    | ($ev | map(select(.kind=="pr")) | INDEX("\(.repo)#\(.pr)")) as $prs
    | ($ev | map(select(.kind=="commit")) | INDEX("\(.repo) \(.sha)")) as $commits
    | ($ev | map(select(.kind=="commit"))) as $all_commits
    | ($ev | map(select(.kind=="cr_ratelimit"))) as $ratelimits

    | def seg($repo; $pr; $anchor_iso):
        ($prs["\($repo)#\($pr)"] // {}) as $p
        | ($anchor_iso | ts) as $e
        | {repo:$repo,
           additions:($p.additions // null),
           additions_bucket:(($p.additions // null) | addbucket),
           hour:($e | gmtime | strftime("%H")),
           weekday:($e | gmtime | strftime("%a"))};
    # A round is rate_limited if CodeRabbit posted a rate-limit notice in this
    # PR between the reviewed commit and the review. Those rounds are handled
    # by the coderabbit-wait.sh retry path, not by max_wait_seconds, so they
    # segment out of the normal-latency basis (rate_limited=true) rather than
    # inflating it, mirroring the rate_limited segmentation in
    # audit-codex-latency.sh.
    def rl($repo; $pr; $from_iso; $to_iso):
        ([ $ratelimits[] | select(.repo==$repo and .pr==$pr
             and .created_at > $from_iso and .created_at < $to_iso) ] | length) > 0;

    [
      # CodeRabbit review-object latency: submitted_at − committer_date(commit_id).
      # Exact commit anchor from the review object; no timeline reconstruction.
      # Dedup key is (repo, PR, commit): the goal is only to collapse the
      # multiple review objects CodeRabbit posts on the SAME commit in the SAME
      # PR (empties from thread resolution + re-reviews). Keying on (repo,
      # commit) alone would also merge reviews of a shared SHA across DIFFERENT
      # PRs (stacked/duplicate PRs), discarding the later PR sample — but
      # coderabbit-wait.sh waits per PR, so each PR review is its own latency
      # event and must be kept (Codex P2 on #688).
      ( ($ev | map(select(.kind=="cr_review" and .commit_id != null and .real_review==true))
         | group_by("\(.repo) \(.pr) \(.commit_id)")
         | map(sort_by(.submitted_at) | .[0]))[] as $r
        | ($commits["\($r.repo) \($r.commit_id)"]
           // ([ $all_commits[] | select(.repo==$r.repo and (.sha | startswith($r.commit_id))) ] | first)) as $c
        | select($c != null)
        | (($r.submitted_at | ts) - ($c.committer_date | ts)) as $sec
        | select($sec >= 0)
        | {pair:"d_cr_review_latency", repo:$r.repo, pr:$r.pr,
           t0:$c.committer_date, t1:$r.submitted_at, seconds:$sec,
           rate_limited:rl($r.repo; $r.pr; $c.committer_date; $r.submitted_at)}
          + seg($r.repo; $r.pr; $c.committer_date) ),

      # Phase-4b adapter latency. A verdict-producing round is a real review;
      # a fail-closed abort (quota/connection UNAVAILABLE) is reported under a
      # separate pair so it never dilutes the review-latency distribution.
      ( $ev[] | select(.kind=="p4b_round") as $q
        | select($q.elapsed_seconds != null and $q.elapsed_seconds >= 0)
        | (if ($q.verdict == "UNAVAILABLE") then "a_p4b_adapter_abort"
           else "a_p4b_adapter_review" end) as $pair
        | {pair:$pair, repo:"phase-4b", pr:null,
           t0:null, t1:null, seconds:$q.elapsed_seconds,
           verdict:$q.verdict, fell_back:$q.fell_back,
           additions_bucket:"n/a", hour:"n/a", weekday:"n/a"} )
    ]
    | flatten
    | map(select(.seconds != null and .seconds >= 0))
    | .[]
  ' "$OUT_DIR/events.jsonl" > "$OUT_DIR/pairs.jsonl"

  log "summarizing → summary.md"
  summarize
}

summarize() {
  jq -rs '
    def pct($p): if length == 0 then null else sort | .[(((length * $p) | ceil) - 1)] end;
    def hms: if . == null then "-"
      else (. | round) as $s
      | if $s >= 3600 then "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m"
        elif $s >= 60 then "\($s / 60 | floor)m\($s % 60)s"
        else "\($s)s" end end;
    def row($label): map(.seconds)
      | "| \($label) | \(length) | \(pct(0.5) | hms) | \(pct(0.9) | hms) | \(pct(0.99) | hms) | \(max // null | hms) |";
    def table($dim): group_by(.[$dim]) | map(row("\($dim)=\(.[0][$dim])")) | join("\n");

    group_by(.pair) | map(
      "## \(.[0].pair)\n\n" +
      "| segment | n | p50 | p90 | p99 | max |\n|---|---|---|---|---|---|\n" +
      row("ALL") + "\n" +
      (if (.[0].repo != "phase-4b") then
        table("repo") + "\n" + table("additions_bucket") + "\n" +
        table("rate_limited") + "\n" +
        table("weekday") + "\n" + table("hour")
       else "" end)
    ) | join("\n\n")
  ' "$OUT_DIR/pairs.jsonl" > "$OUT_DIR/summary.md"
  log "wrote $OUT_DIR/summary.md"
}

# --- main -------------------------------------------------------------------

case "$MODE" in
  full)         fetch_all; normalize; analyze ;;
  fetch-only)   fetch_all ;;
  analyze-only) normalize; analyze ;;
esac

log "done"
