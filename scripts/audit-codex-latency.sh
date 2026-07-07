#!/usr/bin/env bash
# audit-codex-latency.sh — mine actual Codex review latency from historical
# GitHub records and emit per-event-pair percentile distributions (#623).
#
# Every review-cycle wait window in the pipeline (codex.review_timeout_seconds,
# codex.ack_wait_seconds × max_ack_retries, codex.reaction_freshness_window_
# seconds, the */15 and */5 sweep crons) was tuned by folklore. This audit
# replaces the folklore with measurement: it mines events ALREADY RECORDED on
# GitHub — issue comments, comment reactions, reviews, review-thread comments,
# PR metadata, and Actions workflow-run history — and reports n / p50 / p90 /
# p99 / max for each event pair defined in #623, segmented by diff size,
# round number, hour-of-day, weekday, and rate-limited rounds.
#
# METHOD CONSTRAINT (from #623): fully retrospective. This script performs
# ONLY GET requests against the GitHub API. It never posts comments,
# reactions, or review triggers, and it never fabricates or simulates event
# streams — every number comes from a pre-existing GitHub record.
#
# Event pairs (issue #623):
#   1. trigger → 👀 ack          `@codex review` comment created_at → the
#                                bot's `eyes` reaction created_at on it.
#   2. trigger → first finding   → earliest bot inline review comment (or
#                                review submission) in that round.
#   3. trigger → verdict         → the bot's "Codex Review: … Reviewed
#                                commit: <sha>" ISSUE COMMENT (#567 — not a
#                                review object) for that round.
#   4. trigger → 👍 clearance    → the bot's `+1` reaction on the PR ISSUE
#                                (issues/{pr}/reactions — the gate's endpoint,
#                                NOT the trigger comment; #645), paired with
#                                the most recent trigger at or before it.
#   5. push → auto-review        reviewed-commit committer date → verdict,
#                                for verdicts with no preceding trigger in
#                                the round window (Codex auto-reviews).
#   6. clearance → gate → merge  clearance signal (👍 when recorded, else
#                                the affirmative verdict comment) → next
#                                merge-clearance-gate / auto-clear-blocking-
#                                labels run (created_at = cron scheduling
#                                delay, run_started_at − created_at = queue
#                                delay, updated_at = completion) → merged_at.
#
# Implementation notes encoded from #623 (learned the hard way):
#   - `gh api --paginate` on EVERY listing call. A capped sample once falsely
#     showed the bot absent from a busy repo.
#   - Verdicts are ISSUE comments; 👀 is ack-only, never clearance.
#   - Actions run history ages out (~90-day retention): the trimmed run
#     records are persisted as JSONL (raw/runs.jsonl) so the cron-queueing
#     analysis stays reproducible after GitHub deletes the runs. Clearances
#     older than the oldest retained run are excluded from pair 6 rather
#     than mis-paired.
#
# Usage:
#   scripts/audit-codex-latency.sh [--repo owner/name] [--out-dir DIR]
#                                  [--bot-login LOGIN] [--since YYYY-MM-DD]
#                                  [--fetch-only | --analyze-only]
#                                  [--gate-workflows f1.yml,f2.yml]
#
#   --repo            Repo to mine (default: current repo via gh repo view).
#   --out-dir         Output directory (default: .mergepath/codex-latency-audit).
#   --bot-login       Codex bot login prefix (default: chatgpt-codex-connector;
#                     REST reports it with a [bot] suffix, so matching is
#                     prefix-based).
#   --since           Skip per-PR record fetching for PRs created before this
#                     date (bounds API cost on repos with long pre-Codex
#                     history). Default: fetch everything.
#   --fetch-only      Fetch + persist raw records, skip analysis.
#   --analyze-only    Skip fetching; re-run normalize + analysis over an
#                     existing raw extract in --out-dir. This is what keeps
#                     the study reproducible after run-history retention
#                     ages the live records out.
#   --gate-workflows  Comma-separated workflow file names for pair 6
#                     (default: merge-clearance-gate.yml,auto-clear-blocking-labels.yml).
#
# Outputs (under --out-dir):
#   raw/pulls.jsonl            trimmed PR list records
#   raw/pr_meta.jsonl          per-PR additions / merged_at / head
#   raw/issue_comments.jsonl   trimmed PR issue comments (triggers, bot posts)
#   raw/reviews.jsonl          trimmed bot reviews
#   raw/review_comments.jsonl  trimmed bot inline review comments
#   raw/pr_commits.jsonl       sha → committer_date map
#   raw/reactions.jsonl        bot reactions on trigger comments (👀 ack, pair 1)
#   raw/pr_reactions.jsonl     bot reactions on the PR issue (👍 clearance,
#                              pairs 4 & 6 — the gate's endpoint, #645)
#   raw/runs.jsonl             trimmed Actions run records (PERSIST THIS —
#                              GitHub ages runs out after ~90 days)
#   events.jsonl               normalized event stream
#   pairs.jsonl                one record per measured event-pair instance
#   summary.md                 percentile tables per pair and segment
#
# Exit codes:
#   0 — success
#   1 — bad arguments
#   2 — missing dependency (gh, jq) or missing GH_TOKEN
#   3 — GitHub API failure
#
# Read-only guarantee: the only gh invocations in this file are `gh api` GETs
# and `gh repo view`. No comment, reaction, label, review, or trigger is ever
# written; posting `@codex review` anywhere would burn rate-limit budget and
# contaminate the very distributions being measured.

set -euo pipefail

# --- preflight auto-source (#282) ------------------------------------------
# Auto-source the op-preflight cache when GH_TOKEN is unset and a fresh
# cache exists for this agent. This script is read-only, so reviewer scope
# is the right PAT.
__AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# --- shared Codex failure-marker regexes (#722) -----------------------------
# The rate-limit / not-connected marker patterns are canonicalized in
# scripts/lib/codex-failure-markers.sh so the live Phase 4a scripts test the
# SAME patterns this audit classifies (proposal 1 of #722). Hard-require it:
# without it the normalize phase cannot classify the marker events the study
# measures, so a missing lib is a dependency error, not a silent degrade.
if [ -r "$__AUDIT_DIR/lib/codex-failure-markers.sh" ]; then
  # shellcheck source=lib/codex-failure-markers.sh
  . "$__AUDIT_DIR/lib/codex-failure-markers.sh"
else
  echo "ERROR: missing scripts/lib/codex-failure-markers.sh (required for marker classification)" >&2
  exit 2
fi

# --- argument parsing --------------------------------------------------------

REPO=""
OUT_DIR=".mergepath/codex-latency-audit"
BOT_LOGIN="chatgpt-codex-connector"
SINCE=""
MODE="full"   # full | fetch-only | analyze-only
GATE_WORKFLOWS="merge-clearance-gate.yml,auto-clear-blocking-labels.yml"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --repo requires owner/name" >&2; exit 1; }
      REPO="$2"; shift 2 ;;
    --out-dir)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --out-dir requires a path" >&2; exit 1; }
      OUT_DIR="$2"; shift 2 ;;
    --bot-login)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --bot-login requires a login" >&2; exit 1; }
      BOT_LOGIN="$2"; shift 2 ;;
    --since)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --since requires YYYY-MM-DD" >&2; exit 1; }
      SINCE="$2"; shift 2 ;;
    --fetch-only)   MODE="fetch-only"; shift ;;
    --analyze-only) MODE="analyze-only"; shift ;;
    --gate-workflows)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "Error: --gate-workflows requires a list" >&2; exit 1; }
      GATE_WORKFLOWS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

log() { echo "[audit-codex-latency] $*" >&2; }

RAW_DIR="$OUT_DIR/raw"

# --- fetch phase -------------------------------------------------------------

api_get() {
  # gh api --paginate GET wrapper with transient-failure retry. Read-only.
  with_gh_retry gh api --paginate "$@"
}

fetch_all() {
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required for fetching" >&2; exit 2; }
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: GH_TOKEN is required. Either:" >&2
    echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\"" >&2
    echo "    so this helper auto-sources OP_PREFLIGHT_REVIEWER_PAT, OR" >&2
    echo "  - Set GH_TOKEN inline per REVIEW_POLICY.md § PAT lookup table." >&2
    exit 2
  fi
  if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$REPO" ] || { echo "ERROR: could not detect repo; pass --repo owner/name" >&2; exit 1; }
  fi

  mkdir -p "$RAW_DIR"

  # 1. Actions workflow runs FIRST (#623: retention ages these out — persist
  #    before anything else so an interrupted fetch still banks them).
  : > "$RAW_DIR/runs.jsonl"
  local wf __wfs
  IFS=',' read -ra __wfs <<< "$GATE_WORKFLOWS"
  for wf in "${__wfs[@]}"; do
    log "fetching Actions runs for $wf (paginated — this is the long one)"
    api_get "repos/$REPO/actions/workflows/$wf/runs?per_page=100" \
      --jq '.workflow_runs[]' \
      | jq -c --arg wf "$wf" '{workflow:$wf, id, event, status, conclusion,
          created_at, run_started_at, updated_at, head_branch}' \
      >> "$RAW_DIR/runs.jsonl" \
      || { echo "ERROR: failed fetching runs for $wf" >&2; exit 3; }
  done

  # 2. All PRs (state=all, paginated).
  log "fetching PR list"
  api_get "repos/$REPO/pulls?state=all&per_page=100&sort=created&direction=asc" \
    --jq '.[]' \
    | jq -c '{pr:.number, created_at, state, head_ref:.head.ref}' \
    > "$RAW_DIR/pulls.jsonl" \
    || { echo "ERROR: failed fetching PR list" >&2; exit 3; }

  # 3. Per-PR records. --since bounds the sweep on repos with long
  #    pre-Codex history; default is everything (#623: no capped samples).
  : > "$RAW_DIR/pr_meta.jsonl"
  : > "$RAW_DIR/issue_comments.jsonl"
  : > "$RAW_DIR/reviews.jsonl"
  : > "$RAW_DIR/review_comments.jsonl"
  : > "$RAW_DIR/pr_commits.jsonl"
  : > "$RAW_DIR/pr_reactions.jsonl"
  local n
  for n in $(jq -r --arg since "$SINCE" \
      'select($since == "" or .created_at >= $since) | .pr' "$RAW_DIR/pulls.jsonl"); do
    log "fetching PR #$n records"
    with_gh_retry gh api "repos/$REPO/pulls/$n" \
      | jq -c '{pr:.number, created_at, merged_at, closed_at, state,
                additions, head_ref:.head.ref, head_sha:.head.sha}' \
      >> "$RAW_DIR/pr_meta.jsonl" || { echo "ERROR: PR #$n meta fetch failed" >&2; exit 3; }

    # Issue comments: keep any comment that is bot-authored or mentions
    # @codex (triggers). Bodies are kept verbatim — classification happens
    # in ONE place, the normalize phase below.
    api_get "repos/$REPO/issues/$n/comments?per_page=100" --jq '.[]' \
      | jq -c --argjson pr "$n" --arg bot "$BOT_LOGIN" '
          select((.user.login | startswith($bot))
                 or ((.body // "") | test("@codex"; "i")))
          | {pr:$pr, id, login:.user.login, created_at, body}' \
      >> "$RAW_DIR/issue_comments.jsonl" || { echo "ERROR: PR #$n comments fetch failed" >&2; exit 3; }

    # Bot reviews (submission time anchors the inline-finding fallback).
    api_get "repos/$REPO/pulls/$n/reviews?per_page=100" --jq '.[]' \
      | jq -c --argjson pr "$n" --arg bot "$BOT_LOGIN" '
          select(.user.login | startswith($bot))
          | {pr:$pr, id, login:.user.login, submitted_at, commit_id, state}' \
      >> "$RAW_DIR/reviews.jsonl" || { echo "ERROR: PR #$n reviews fetch failed" >&2; exit 3; }

    # Bot inline review comments (pair 2's primary signal).
    api_get "repos/$REPO/pulls/$n/comments?per_page=100" --jq '.[]' \
      | jq -c --argjson pr "$n" --arg bot "$BOT_LOGIN" '
          select(.user.login | startswith($bot))
          | {pr:$pr, id, login:.user.login, created_at,
             review_id:.pull_request_review_id}' \
      >> "$RAW_DIR/review_comments.jsonl" || { echo "ERROR: PR #$n review comments fetch failed" >&2; exit 3; }

    # Commit committer dates (round-head + push-time anchors, pair 5).
    api_get "repos/$REPO/pulls/$n/commits?per_page=100" --jq '.[]' \
      | jq -c '{sha, committer_date:.commit.committer.date}' \
      >> "$RAW_DIR/pr_commits.jsonl" || { echo "ERROR: PR #$n commits fetch failed" >&2; exit 3; }

    # PR-issue reactions (pair 4 👍 clearance + pair 6 reaction clearance).
    # The clearance 👍 lives on the PR ISSUE, not the trigger comment — the
    # merge gate reads repos/$REPO/issues/$PR/reactions (codex-review-check.sh),
    # so that is the endpoint the audit must mine for it too (#645). The 👀
    # ack, by contrast, IS on the trigger comment and stays in reactions.jsonl.
    api_get "repos/$REPO/issues/$n/reactions?per_page=100" --jq '.[]' \
      | jq -c --argjson pr "$n" --arg bot "$BOT_LOGIN" '
          select(.user.login | startswith($bot))
          | {pr:$pr, content, created_at, login:.user.login}' \
      >> "$RAW_DIR/pr_reactions.jsonl" || { echo "ERROR: PR #$n issue reactions fetch failed" >&2; exit 3; }
  done

  # 4. Reactions on every trigger comment (pairs 1 and 4). Trigger ids come
  #    from the comments just fetched; the reactions endpoint is paginated
  #    like everything else.
  : > "$RAW_DIR/reactions.jsonl"
  local cid cpr
  while IFS=$'\t' read -r cpr cid; do
    api_get "repos/$REPO/issues/comments/$cid/reactions?per_page=100" --jq '.[]' \
      | jq -c --argjson pr "$cpr" --argjson cid "$cid" \
          '{pr:$pr, comment_id:$cid, content, created_at, login:.user.login}' \
      >> "$RAW_DIR/reactions.jsonl" \
      || { echo "ERROR: reactions fetch failed for comment $cid" >&2; exit 3; }
  done < <(jq -r --arg bot "$BOT_LOGIN" '
      select((.login | startswith($bot) | not)
             and ((.body // "") | test("@codex review"; "i")))
      | [.pr, .id] | @tsv' "$RAW_DIR/issue_comments.jsonl")

  # 5. Committer dates for anchor shas that are not in pr_commits (force-
  #    pushed-away round heads are unreachable from the final head). The
  #    wanted set is the union of verdict-comment "Reviewed commit" shas
  #    AND bot review commit_ids — pair 5 consumes review-object-only
  #    auto-reviews too, and dropping their anchors would silently censor
  #    them (Codex P2 on #629).
  local sha
  while IFS= read -r sha; do
    with_gh_retry gh api "repos/$REPO/commits/$sha" \
      --jq '{sha:.sha, committer_date:.commit.committer.date}' 2>/dev/null \
      | jq -c '.' >> "$RAW_DIR/pr_commits.jsonl" \
      || log "WARN: commit $sha not fetchable (deleted branch?) — pair-5 anchor unavailable for it"
  done < <(
    {
      jq -rs --arg bot "$BOT_LOGIN" '
        (map(select((.login | startswith($bot))
                    and ((.body // "") | test("(?i)codex review"))
                    and ((.body // "") | test("(?i)reviewed commit"))))
         | map((.body | ascii_downcase
                | [scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")]
                | (last // [])[0]) // empty)) as $want
        | $want[]' "$RAW_DIR/issue_comments.jsonl"
      jq -r 'select(.commit_id != null) | .commit_id | ascii_downcase' \
        "$RAW_DIR/reviews.jsonl"
    } \
    | sort -u \
    | grep -vxF -f <(jq -r '.sha' "$RAW_DIR/pr_commits.jsonl" | sort -u) || true
  )

  log "raw extract complete under $RAW_DIR"
}

# --- normalize phase ---------------------------------------------------------
# One classification pass, in one place. Emits the normalized event stream
# that the analysis operates on. Comment-body regexes mirror
# codex-review-check.sh's verdict matcher (#567/#600).

normalize() {
  # Events/pairs-only replay mode: when no raw extract is present but a
  # normalized events.jsonl already exists (e.g. the committed
  # docs/audits/data/ extract copied into --out-dir), reuse it — this is
  # what keeps the published summary recomputable after GitHub retention
  # ages the live records out (Codex P2 on #629).
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

    jq -c '{kind:"commit", sha, committer_date}' "$RAW_DIR/pr_commits.jsonl"

    jq -c --arg bot "$BOT_LOGIN" \
          --arg rate_re "$CODEX_USAGE_LIMIT_MARKER_RE" \
          --arg nc_re "$CODEX_NOT_CONNECTED_MARKER_RE" '
      if (.login | startswith($bot)) then
        # Verdict = a line-anchored "Codex Review:" bot comment (#567).
        # The "**Reviewed commit:** `sha`" line only exists in the NEWER
        # verdict format — older verdicts carry no sha and normalize with
        # reviewed_sha:null (they still pair by time for pair 3; they are
        # skipped for pair 5, which needs the sha as its push anchor).
        if ((.body // "") | test("(?im)^\\s*codex review:")) then
          {kind:"verdict", pr, comment_id:.id, created_at,
           reviewed_sha:((.body | ascii_downcase
             | [scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")]
             | (last // [])[0]) // null),
           affirmative:(.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b"))}
        # Rate-limit / usage-limit / quota marker. Pattern shared with the
        # live scripts via scripts/lib/codex-failure-markers.sh (#722); the
        # inline (?i) flag is replaced by the test() "i" flag so the stored
        # literal is flag-free and reusable.
        elif ((.body // "") | test($rate_re; "i")) then
          {kind:"rate_limit", pr, comment_id:.id, created_at}
        # Dropped-trigger markers (#570 class): the app was not connected /
        # had no environment, so the trigger produced no round at all.
        elif ((.body // "") | test($nc_re; "i")) then
          {kind:"dropped_trigger_marker", pr, comment_id:.id, created_at}
        else
          {kind:"bot_comment_other", pr, comment_id:.id, created_at,
           excerpt:((.body // "")[0:160])}
        end
      # Trigger = a line-anchored `@codex review` from a non-bot author.
      # Line-anchoring drops comments that merely QUOTE the trigger phrase
      # mid-sentence (runbook excerpts, handoff notes), which would
      # otherwise register as extra rounds and shrink measured latencies.
      elif (((.body // "") | test("(?im)^\\s*@codex review\\b"))
            and ((.login | test("(?i)coderabbit")) | not)) then
        {kind:"trigger", pr, comment_id:.id, created_at, author:.login}
      else empty end' "$RAW_DIR/issue_comments.jsonl"

    jq -c '{kind:"review", pr, review_id:.id, submitted_at, commit_id, state}' \
      "$RAW_DIR/reviews.jsonl"

    jq -c '{kind:"review_comment", pr, comment_id:.id, created_at, review_id}' \
      "$RAW_DIR/review_comments.jsonl"

    if [ -s "$RAW_DIR/reactions.jsonl" ]; then
      jq -c --arg bot "$BOT_LOGIN" '
        select(.login | startswith($bot))
        | {kind:"reaction", pr, comment_id, content, created_at}' \
        "$RAW_DIR/reactions.jsonl"
    fi

    if [ -s "$RAW_DIR/pr_reactions.jsonl" ]; then
      jq -c --arg bot "$BOT_LOGIN" '
        select(.login | startswith($bot))
        | {kind:"pr_reaction", pr, content, created_at}' \
        "$RAW_DIR/pr_reactions.jsonl"
    fi

    jq -c '{kind:"run", workflow, run_id:.id, event, conclusion,
            created_at, run_started_at, updated_at, head_branch}' \
      "$RAW_DIR/runs.jsonl"
  } > "$OUT_DIR/events.jsonl"
}

# --- analysis phase ----------------------------------------------------------

analyze() {
  [ -s "$OUT_DIR/events.jsonl" ] || { echo "ERROR: $OUT_DIR/events.jsonl is missing or empty" >&2; exit 1; }
  log "pairing events → pairs.jsonl"

  jq -cs '
    def ts: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
    def addbucket: if . == null then "unknown"
      elif . <= 50 then "additions<=50" elif . <= 150 then "additions=51-150"
      elif . <= 300 then "additions=151-300" elif . <= 1000 then "additions=301-1000"
      else "additions>1000" end;

    map(select(.kind != null)) as $ev
    | ($ev | map(select(.kind=="pr")) | INDEX(.pr | tostring)) as $prs
    | ($ev | map(select(.kind=="commit")) | INDEX(.sha)) as $commits
    | ($ev | map(select(.kind=="reaction"))) as $reactions
    | ($ev | map(select(.kind=="pr_reaction"))) as $pr_reactions
    | ($ev | map(select(.kind=="review_comment"))) as $rcs
    | ($ev | map(select(.kind=="review"))) as $reviews
    | ($ev | map(select(.kind=="rate_limit"))) as $rls
    | ($ev | map(select(.kind=="run")) | sort_by(.created_at)) as $runs
    | ($runs | map(.workflow) | unique) as $workflows
    # Retention guard: pair 6 only for clearances inside the retained run
    # window, per workflow — an older clearance would mis-pair with the
    # oldest RETAINED run, not the run that actually swept it.
    | (reduce $workflows[] as $w ({}; . + {($w): ([ $runs[] | select(.workflow==$w) | .created_at ] | min)})) as $oldest_run

    # ---- rounds: triggers + matched verdicts -------------------------------
    | ($ev | map(select(.kind=="trigger")) | group_by(.pr)
       | map(sort_by(.created_at) | to_entries
             | map(.value + {round:(.key + 1)}))
       | flatten) as $triggers
    | ($ev | map(select(.kind=="verdict")) | sort_by(.created_at)) as $verdicts

    # Failure markers (rate-limit / not-connected) CONSUME the trigger they
    # answer: a later bot response belongs to a new implicit round, not to
    # the failed trigger — binding it would inflate trigger→verdict with
    # exactly the non-response cases this audit measures (Codex P2 on #629).
    | ($ev | map(select(.kind == "rate_limit" or .kind == "dropped_trigger_marker"))) as $failmarkers

    # verdict → owning trigger: latest trigger in the same PR at or before
    # the verdict with no earlier verdict OR failure marker in between
    # (re-reviews of a new push without a fresh trigger, and responses
    # after a failed trigger, classify as auto-review, pair 5).
    | ($verdicts | map(. as $v
        | ([ $triggers[] | select(.pr == $v.pr and .created_at <= $v.created_at) ]
           | sort_by(.created_at) | last) as $t
        | ([ $verdicts[] | select(.pr == $v.pr and .created_at < $v.created_at
                                  and ($t != null) and .created_at >= $t.created_at) ]
           | length) as $stolen
        | ([ $failmarkers[] | select(.pr == $v.pr and ($t != null)
                                     and .created_at >= $t.created_at
                                     and .created_at < $v.created_at) ]
           | length) as $consumed
        | if $t == null or $stolen > 0 or $consumed > 0
          then $v + {matched:false}
          else $v + {matched:true, trigger:$t} end)) as $mverdicts

    # Trigger-less bot REVIEW objects are auto-reviews too: on some rounds
    # Codex leaves only a review submission (no verdict issue comment, no
    # trigger). A review is an auto-review when it has no OWNING trigger —
    # same rule as $mverdicts: the latest prior trigger only owns the
    # review if no other bot response (verdict or earlier review) already
    # answered it in between. "Any prior trigger disqualifies" would drop
    # later review-only rounds on PRs that were triggered once early on.
    # Deduped against verdict comments posted alongside the same review
    # (within 300s in the same PR).
    | ($reviews | map(. as $r
        | ([ $triggers[] | select(.pr == $r.pr and .created_at <= $r.submitted_at) ]
           | sort_by(.created_at) | last) as $t
        | select(
            $t == null
            or ([ $verdicts[] | select(.pr == $r.pr and .created_at >= $t.created_at
                                       and .created_at < $r.submitted_at) ] | length) > 0
            or ([ $reviews[] | select(.pr == $r.pr and .review_id != $r.review_id
                                      and .submitted_at >= $t.created_at
                                      and .submitted_at < $r.submitted_at) ] | length) > 0
            or ([ $failmarkers[] | select(.pr == $r.pr and .created_at >= $t.created_at
                                          and .created_at < $r.submitted_at) ] | length) > 0)
        | select(([ $verdicts[] | select(.pr == $r.pr
                     and (((.created_at | ts) - ($r.submitted_at | ts)) | fabs) <= 300) ] | length) == 0)
        | $r)) as $auto_reviews

    | (reduce $rls[] as $rl ({};
        .[($rl.pr | tostring)] = ((.[($rl.pr | tostring)] // []) + [$rl.created_at]))) as $rl_by_pr

    # rate_limited is bounded to the ACTIVE round: a marker only taints the
    # segment if it lands before the next trigger in the PR — otherwise a
    # rate-limit marker from a later round would mislabel an earlier,
    # healthy round (Codex P2 on #629; observed shape on PRs 507/565).
    | def seg($pr; $t0):
        ($prs[$pr | tostring] // {}) as $p
        | ($t0 | ts) as $e
        | ([ $triggers[] | select(.pr == $pr and .created_at > $t0) ]
           | sort_by(.created_at) | first) as $nt
        | {additions:($p.additions // null),
           additions_bucket:(($p.additions // null) | addbucket),
           hour:($e | gmtime | strftime("%H")),
           weekday:($e | gmtime | strftime("%a")),
           rate_limited:(
             [ ($rl_by_pr[$pr | tostring] // [])[]
               | select(. >= $t0 and ((. | ts) - $e) <= 7200
                        and ($nt == null or . < $nt.created_at)) ] | length > 0)};

    [
      # pair 1: 👀 ack — a reaction on the TRIGGER COMMENT (correct endpoint;
      # Codex acks the trigger it was mentioned in).
      ( $triggers[] as $t
        | $reactions[]
        | select(.comment_id == $t.comment_id and .created_at >= $t.created_at)
        | select(.content == "eyes")
        | {pair:"1_trigger_to_ack",
           pr:$t.pr, round:$t.round, t0:$t.created_at, t1:.created_at,
           seconds:((.created_at | ts) - ($t.created_at | ts))}
          + seg($t.pr; $t.created_at) ),

      # pair 4: trigger → 👍 clearance. The clearance 👍 is on the PR ISSUE
      # (repos/$REPO/issues/$PR/reactions), where the merge gate reads it —
      # NOT the trigger comment (#645). Pair each PR-issue +1 with the most
      # recent trigger at or before it (the round that 👍 cleared).
      ( $pr_reactions[]
        | select(.content == "+1") as $r
        | ([ $triggers[]
             | select(.pr == $r.pr and .created_at <= $r.created_at) ]
           | sort_by(.created_at) | last) as $t
        | select($t != null)
        | {pair:"4_trigger_to_thumbs_clearance",
           pr:$r.pr, round:$t.round, t0:$t.created_at, t1:$r.created_at,
           seconds:(($r.created_at | ts) - ($t.created_at | ts))}
          + seg($r.pr; $t.created_at) ),

      # pair 2: trigger → earliest bot inline FINDING. A review submission
      # only counts when it carries at least one inline comment — a clean /
      # summary-only review is not a finding and would inflate the sample
      # (Codex P2 on #629). The unrestricted first-response time is emitted
      # separately as pair 2b (a useful proxy when inline comments were not
      # mined), never conflated with pair 2.
      ( $triggers[] as $t
        | ([ ($rcs[] | select(.pr == $t.pr) | {at:.created_at}),
             ($reviews[] | select(.pr == $t.pr) as $rv
              | select(([ $rcs[] | select(.review_id == $rv.review_id) ] | length) > 0)
              | {at:$rv.submitted_at}) ]
           | map(select(.at > $t.created_at)) | sort_by(.at) | first) as $f
        | select($f != null)
        # attribute to this round only if no later trigger precedes it
        | select(([ $triggers[] | select(.pr == $t.pr and .created_at > $t.created_at
                                         and .created_at < $f.at) ] | length) == 0)
        # ...and the round is still open: a verdict before the finding
        # closes the round, so a later review submission belongs to a
        # subsequent (auto-review) round, not to this trigger (Codex P2
        # on #629; observed shape on PRs 358/416/565).
        | select(([ $verdicts[] | select(.pr == $t.pr and .created_at > $t.created_at
                                         and .created_at < $f.at) ] | length) == 0)
        # ...and no failure marker consumed the trigger first: a rate-limited
        # or not-connected round produces NO finding sample — a later response
        # belongs to a later round (4b P1 + Codex P2 on #629; symmetric with
        # the verdict matcher, which already treats markers as consuming).
        | select(([ $failmarkers[] | select(.pr == $t.pr and .created_at >= $t.created_at
                                            and .created_at < $f.at) ] | length) == 0)
        | {pair:"2_trigger_to_first_finding", pr:$t.pr, round:$t.round,
           t0:$t.created_at, t1:$f.at,
           seconds:(($f.at | ts) - ($t.created_at | ts))}
          + seg($t.pr; $t.created_at) ),

      # pair 2b: trigger → first review response of ANY kind (clean or
      # findings-bearing review submission, or inline comment). This is the
      # proxy an extract without mined inline comments can still measure.
      ( $triggers[] as $t
        | ([ ($rcs[] | select(.pr == $t.pr) | {at:.created_at}),
             ($reviews[] | select(.pr == $t.pr) | {at:.submitted_at}) ]
           | map(select(.at > $t.created_at)) | sort_by(.at) | first) as $f
        | select($f != null)
        | select(([ $triggers[] | select(.pr == $t.pr and .created_at > $t.created_at
                                         and .created_at < $f.at) ] | length) == 0)
        | select(([ $verdicts[] | select(.pr == $t.pr and .created_at > $t.created_at
                                         and .created_at < $f.at) ] | length) == 0)
        # same failure-marker cutoff as pair 2 (4b P1 on #629).
        | select(([ $failmarkers[] | select(.pr == $t.pr and .created_at >= $t.created_at
                                            and .created_at < $f.at) ] | length) == 0)
        | {pair:"2b_trigger_to_first_review_response", pr:$t.pr, round:$t.round,
           t0:$t.created_at, t1:$f.at,
           seconds:(($f.at | ts) - ($t.created_at | ts))}
          + seg($t.pr; $t.created_at) ),

      # pair 3: trigger → verdict issue comment
      ( $mverdicts[] | select(.matched)
        | {pair:"3_trigger_to_verdict", pr, round:.trigger.round,
           t0:.trigger.created_at, t1:.created_at,
           seconds:((.created_at | ts) - (.trigger.created_at | ts))}
          + seg(.pr; .trigger.created_at) ),

      # pair 5: push → auto-review (no owning trigger), from verdict
      # comments and from trigger-less review objects
      ( ( ($mverdicts[] | select(.matched | not)
           | {pr, at:.created_at, sha:.reviewed_sha}),
          ($auto_reviews[] | {pr, at:.submitted_at, sha:.commit_id}) ) as $v
        | ($commits[$v.sha // ""]
           // ([ $commits[] | select($v.sha != null
                                     and (.sha | startswith($v.sha))) ] | first)) as $c
        | select($c != null)
        | select(($c.committer_date | ts) <= ($v.at | ts))
        | {pair:"5_push_to_auto_review", pr:$v.pr, round:null,
           t0:$c.committer_date, t1:$v.at,
           seconds:(($v.at | ts) - ($c.committer_date | ts))}
          + seg($v.pr; $c.committer_date) ),

      # pair 6: clearance → gate run → merge, per gate workflow.
      # Clearance = the operative (last-before-merge) 👍 reaction on the PR
      # ISSUE when recorded (the gate endpoint, #645), else the last
      # affirmative verdict comment
      # ANCHORED ON THE MERGE HEAD — the merge gate treats a verdict on a
      # pre-push commit as stale (#567/#600), so a sha-mismatched (or
      # sha-less old-format) verdict is not the operative clearance and is
      # excluded fail-closed rather than mis-anchored (Codex P2 on #629).
      ( $prs[] | select(.merged_at != null) as $p
        # merge-head commit record, for anchoring reaction clearances: the
        # gate treats a 👍 older than the merge-head push as stale (its
        # reaction_threshold is the HEAD committer date, #567/#600), so a
        # thumbs-up on a superseded push is not the operative clearance.
        # Fail-closed when the head commit is missing from the extract
        # (4b P1 on #629; mirrors the sha-anchored verdict rule below).
        | ($commits[$p.head_sha // ""] // null) as $hc
        | ([ ( $pr_reactions[] | select(.content == "+1")
               | select(.pr == $p.pr)
               | select($hc != null and (.created_at >= $hc.committer_date))
               | .created_at ),
             ( $mverdicts[] | . as $mv
               | select($mv.pr == $p.pr and $mv.affirmative == true
                        and $mv.reviewed_sha != null
                        and (($p.head_sha // "") | startswith($mv.reviewed_sha)))
               | $mv.created_at ) ]
           | map(select(. <= $p.merged_at)) | sort | last) as $clear
        | select($clear != null)
        | (
            ( {pair:"6_clearance_to_merge", pr:$p.pr, round:null,
               t0:$clear, t1:$p.merged_at,
               seconds:(($p.merged_at | ts) - ($clear | ts))}
              + seg($p.pr; $clear) ),
            # Only runs that could have swept THIS PR count: schedule /
            # workflow_dispatch runs are repo-wide sweeps; event-triggered
            # runs only touch the PR whose head branch they ran on. Two
            # further guards (Codex P2s on #629): the run must have
            # CONCLUDED SUCCESS (a skipped/failed run cannot clear labels
            # or satisfy the required check), and it must have been created
            # BEFORE the merge — a post-merge sweep cannot be the gate leg
            # of clearance→gate→merge; clearances whose first eligible run
            # postdates the merge are censored (skipped), not mis-paired.
            ( $workflows[] as $w
              | select(($oldest_run[$w] // null) != null and $clear >= $oldest_run[$w])
              | ([ $runs[] | select(.workflow == $w and .created_at >= $clear
                                    and .created_at <= $p.merged_at
                                    and .conclusion == "success"
                                    and (.event == "schedule" or .event == "workflow_dispatch"
                                         or .head_branch == $p.head_ref)) ] | first) as $r
              | select($r != null)
              | seg($p.pr; $clear) as $s
              | {pr:$p.pr, round:null, t0:$clear, gate_event:$r.event} + $s
              | ( . + {pair:("6_clearance_to_gate:" + $w), t1:$r.created_at,
                       seconds:(($r.created_at | ts) - ($clear | ts))} ),
                ( . + {pair:("6_gate_queue:" + $w), t1:($r.run_started_at // $r.created_at),
                       seconds:((($r.run_started_at // $r.created_at) | ts) - ($r.created_at | ts))} ),
                ( select($r.updated_at != null and $r.run_started_at != null)
                  | . + {pair:("6_gate_run:" + $w), t1:$r.updated_at,
                         seconds:(($r.updated_at | ts) - ($r.run_started_at | ts))} ) )
          )
      )
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
      table("additions_bucket") + "\n" +
      (if (.[0].round != null) then (map(select(.round != null)) |
        (group_by(if .round >= 3 then "3+" else (.round | tostring) end)
         | map(row("round=\(if .[0].round >= 3 then "3+" else (.[0].round | tostring) end)")) | join("\n")) + "\n")
       else "" end) +
      table("weekday") + "\n" +
      table("hour") + "\n" +
      table("rate_limited")
    ) | join("\n\n")
  ' "$OUT_DIR/pairs.jsonl" > "$OUT_DIR/summary.md"

  # Diagnostics appendix: unclassified bot comments. If a Codex message
  # class (e.g. a new rate-limit marker wording) is not matched by the
  # normalize regexes, it surfaces here instead of silently skewing the
  # rate-limited segmentation.
  {
    echo
    echo "## Appendix: unclassified bot comments (top 20 shapes)"
    echo
    jq -rs '
      map(select(.kind == "bot_comment_other") | .excerpt)
      | group_by(.) | map({excerpt:.[0], n:length}) | sort_by(-.n) | .[:20][]
      # Escape markdown emphasis/code markers from the raw bot text so a
      # stray */_/` in an excerpt cannot garble the rendered appendix.
      | "- (n=\(.n)) \(.excerpt | gsub("\n"; " ") | gsub("(?<c>[*_`])"; "\\\(.c)") | .[0:140])"
    ' "$OUT_DIR/events.jsonl"
  } >> "$OUT_DIR/summary.md"

  log "wrote $OUT_DIR/summary.md"
}

# --- main --------------------------------------------------------------------

case "$MODE" in
  full)         fetch_all; normalize; analyze ;;
  fetch-only)   fetch_all ;;
  analyze-only) normalize; analyze ;;
esac

log "done"
