#!/usr/bin/env bash
# scripts/daily-feedback-rollup.sh
#
# Daily end-of-day rollup of bot-review threads that were resolved on
# this repo's PRs in the last 24h **without** an associated fix
# commit or substantive reply. Files two GitHub Issues per day, one
# per track (substantive / polish), so the deferred-and-forgotten
# class of feedback gets surfaced while the context is still hot.
#
# Implements the first slice of mergepath#299 + the v2 dedupe pass
# from mergepath#304. The remaining follow-up explicitly NOT in this
# script:
#
#   - Agent-side `[mergepath-resolve:<class>]` tag emission in
#     `scripts/resolve-pr-threads.sh`. This script reads the tag if
#     present (forward-compatibility) and falls back to heuristics
#     when it isn't.
#
# Dedupe pass (#304): before emitting today's per-track NDJSON, the
# script fetches the set of already-triaged `mp-id`s from prior
# rollups (open + recently-closed in the 14-day window) and filters
# them out. Triage signals: `[x]`, `[~]`, strikethrough, `#N` ref on
# the line, or a closed host issue (implies all its items triaged).
#
# Architecture mirrors `scripts/sweep-unresolved-feedback/enumerate.sh`
# + `render.sh` but inverted: enumerate looks for UNresolved feedback
# on closed PRs; this script looks for RESOLVED feedback on
# yesterday-merged PRs that wasn't actually addressed.
#
# Usage:
#   daily-feedback-rollup.sh                       # post issues
#   daily-feedback-rollup.sh --dry-run             # print NDJSON, no issue mutation
#   daily-feedback-rollup.sh --since YYYY-MM-DD    # explicit window start
#   daily-feedback-rollup.sh --until YYYY-MM-DD    # explicit window end
#
# Environment:
#   GH_TOKEN                  required. Reads from this repo's PRs +
#                             writes issues. PAT must have
#                             repo:public_repo or repo scope.
#   REPO                      owner/repo (default: current repo
#                             resolved via `gh repo view`).
#   ROLLUP_SUBSTANTIVE_LABEL  default: deferred-feedback-rollup
#   ROLLUP_POLISH_LABEL       default: polish-feedback-rollup
#   ROLLUP_SUBSTANTIVE_THROTTLE  default: 5 (unchecked-items threshold
#                                for appending to existing issue
#                                instead of opening a new one)
#   ROLLUP_POLISH_THROTTLE       default: 20
#   ROLLUP_MAX_PRS_PER_DAY    safety cap, default 100
#   ROLLUP_AGENT_AUTHORS      colon-separated list of agent author
#                             logins (default:
#                             nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex)
#
# Exit codes:
#   0   success (one or both rollup issues posted, or no surfaceable
#       items today)
#   1   setup error (missing dep, GH_TOKEN unset, REPO unresolvable)
#   2   API error (gh GraphQL failure, issue create failure)
#
# Bash 3.2 compatible (macOS default + ubuntu-latest).

set -euo pipefail

DRY_RUN=false
SINCE=""
UNTIL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --since)
      # Arity guard: `--since` without a value would crash with
      # `$2: unbound variable` under set -u. Surface a clean usage
      # error instead (CodeRabbit Minor r4 on PR #303).
      if [ $# -lt 2 ]; then
        echo "Error: --since requires a value (YYYY-MM-DD or RFC3339 timestamp)" >&2
        exit 1
      fi
      SINCE="$2"; shift 2 ;;
    --until)
      if [ $# -lt 2 ]; then
        echo "Error: --until requires a value (YYYY-MM-DD or RFC3339 timestamp)" >&2
        exit 1
      fi
      UNTIL="$2"; shift 2 ;;
    --help|-h) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

for dep in gh jq shasum; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "daily-feedback-rollup: required dependency missing: $dep" >&2
    exit 1
  fi
done

# Source the pure-function helpers so the same classification logic
# is exercised by tests/test_daily_feedback_rollup.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/daily-feedback-rollup-helpers.sh"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "daily-feedback-rollup: GH_TOKEN not set." >&2
  exit 1
fi

REPO="${REPO:-$(gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null || true)}"
if [ -z "$REPO" ]; then
  echo "daily-feedback-rollup: could not resolve REPO. Set REPO=owner/name or run inside a gh-aware checkout." >&2
  exit 1
fi
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

SUBSTANTIVE_LABEL="${ROLLUP_SUBSTANTIVE_LABEL:-deferred-feedback-rollup}"
POLISH_LABEL="${ROLLUP_POLISH_LABEL:-polish-feedback-rollup}"
SUBSTANTIVE_THROTTLE="${ROLLUP_SUBSTANTIVE_THROTTLE:-5}"
POLISH_THROTTLE="${ROLLUP_POLISH_THROTTLE:-20}"
MAX_PRS_PER_DAY="${ROLLUP_MAX_PRS_PER_DAY:-100}"
AGENT_AUTHORS="${ROLLUP_AGENT_AUTHORS:-nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}"
# Dedupe window (in days): prior rollups closed more than N days ago
# are presumed stale and their items re-list per #304 spec. Open
# rollups always contribute regardless of age.
DEDUPE_WINDOW_DAYS="${ROLLUP_DEDUPE_WINDOW_DAYS:-14}"
# Cap on prior rollups to scan per label (safety net against runaway
# label scopes). The 14-day window already bounds expected volume;
# this is belt-and-suspenders.
MAX_PRIOR_ROLLUPS_PER_LABEL="${ROLLUP_MAX_PRIOR_ROLLUPS_PER_LABEL:-50}"
# Body-size policy (#400, revised per #401 Phase-4b review). GitHub caps
# issue/comment bodies at 65536 bytes (the #397 failure mode). The daily
# job scans ONLY the current per-day window, so a finding not recorded in
# the issue BODY (the one surface the dedupe pass reads) is lost for good
# once the window advances — capping-and-dropping would silently lose it.
# We therefore render EVERY finding into the body: the top-N highest-
# severity inline with full detail, the rest in a collapsed <details>
# block (trimmed, then mp-id stubs) so all mp-ids stay dedupe-readable. If
# even stubs won't fit under ROLLUP_BODY_BUDGET we FAIL LOUD rather than
# drop. Paired with the --body-file switch (avoids the lower ARG_MAX
# ceiling that --body hits first).
ROLLUP_MAX_VISIBLE="${ROLLUP_MAX_VISIBLE:-60}"
# Whole-body byte budget; headroom under GitHub's hard 65536 cap.
ROLLUP_BODY_BUDGET="${ROLLUP_BODY_BUDGET:-64000}"

# Compute the window. Default: yesterday 00:00:00Z → today 00:00:00Z UTC.
# BSD date (macOS) and GNU date have divergent flag syntax — try GNU first.
if [ -z "$SINCE" ]; then
  if date -u -d "@0" '+%Y-%m-%d' >/dev/null 2>&1; then
    SINCE=$(date -u -d "1 day ago" '+%Y-%m-%dT00:00:00Z')
  else
    SINCE=$(date -u -v-1d '+%Y-%m-%dT00:00:00Z')
  fi
elif [ "${#SINCE}" -eq 10 ]; then
  SINCE="${SINCE}T00:00:00Z"
fi
if [ -z "$UNTIL" ]; then
  UNTIL=$(date -u '+%Y-%m-%dT00:00:00Z')
elif [ "${#UNTIL}" -eq 10 ]; then
  UNTIL="${UNTIL}T00:00:00Z"
fi

# Date stamp for the rollup issue title (uses SINCE date).
DATE_STAMP="${SINCE%T*}"

echo "daily-feedback-rollup: repo=$REPO window=[$SINCE, $UNTIL) date_stamp=$DATE_STAMP" >&2

# ---------------------------------------------------------------------
# Step 1 — fetch PRs merged in the window
# ---------------------------------------------------------------------

# Use the search API. `is:merged merged:>=...` scopes the scan to
# PRs that actually merged in the window — abandoned (closed-without-
# merge) PRs are excluded because their unaddressed feedback is
# typically not actionable (the work didn't land). The earlier broader
# `closed:>=$SINCE` scope swept those in, producing rollup entries
# with `mergedAt: n/a` that confused triage (CodeRabbit Major r2 on
# PR #303).
#
# No `|| echo '[]'` fallback: an API failure here (auth, rate limit,
# network) MUST fail the run loudly. Treating a failed call as "zero
# PRs" makes deferred feedback silently disappear, which is exactly
# the failure mode this whole script exists to prevent (CodeRabbit
# Major r1 on PR #303).
if ! prs_json=$(gh pr list \
    --repo "$REPO" \
    --state merged \
    --search "is:merged merged:>=$SINCE merged:<$UNTIL" \
    --limit "$MAX_PRS_PER_DAY" \
    --json number,title,url,mergedAt); then
  echo "daily-feedback-rollup: ERROR — gh pr list failed (auth/rate-limit/network?). Aborting rather than producing an empty rollup." >&2
  exit 2
fi

pr_count=$(printf '%s' "$prs_json" | jq 'length')
echo "daily-feedback-rollup: $pr_count PRs in window" >&2

# Counters for the methodology footer. COUNT_FIX uses the weaker
# per-PR heuristic (any agent-author commit on the PR after the
# comment's createdAt) rather than the spec's per-file variant —
# see the Heuristic 2 block below for the trade-off rationale.
COUNT_FIX=0
COUNT_REPLY=0
COUNT_STALE=0
COUNT_TAGGED_SKIP=0
COUNT_TAGGED_SURFACE=0
COUNT_DEFERRED_UNTAGGED=0
# Dedupe pass (#304): items skipped because their mp-id appears
# triaged on a prior rollup issue (open in the 14-day window OR
# closed in that window). Surfaces in the methodology footer.
COUNT_DEDUP_SKIPPED=0
# Tracks per-prior-rollup fetch failures so the script can warn but
# continue: dedupe is best-effort — if we can't read a prior rollup,
# the worst case is re-listing an already-triaged item, which is the
# pre-#304 behaviour. Loud warn + continue beats fail-closed here.
DEDUP_FETCH_FAILURES=0
# Tracks per-PR GraphQL failures so the run can exit non-zero at the
# end. v1 has no persistence/dedupe — silently dropping a transient
# failure's PR data means missing triage signal that never recovers
# (the daily window slides forward). CodeRabbit Major r4 on PR #303.
FAILED_PR_COUNT=0
FAILED_PR_LIST=""

# Per-track NDJSON streams. Each surviving item gets one line.
SUBSTANTIVE_NDJSON=$(mktemp "${TMPDIR:-/tmp}/rollup-sub-XXXXXX.ndjson")
POLISH_NDJSON=$(mktemp "${TMPDIR:-/tmp}/rollup-pol-XXXXXX.ndjson")
trap 'rm -f "$SUBSTANTIVE_NDJSON" "$POLISH_NDJSON"' EXIT

# ---------------------------------------------------------------------
# Step 2 — for each PR, fetch + classify threads
# ---------------------------------------------------------------------

i=0
while [ "$i" -lt "$pr_count" ]; do
  pr_number=$(printf '%s' "$prs_json" | jq -r ".[$i].number")
  pr_title=$(printf '%s' "$prs_json" | jq -r ".[$i].title")
  pr_url=$(printf '%s' "$prs_json" | jq -r ".[$i].url")
  pr_merged_at=$(printf '%s' "$prs_json" | jq -r ".[$i].mergedAt // \"\"")
  i=$((i + 1))

  # GraphQL: pull resolved review threads with full comment chain and
  # the PR's commit list. We need the comment chain to detect
  # substantive replies + the canonical tag, and the commit list to
  # detect fix commits.
  threads_json=$(gh api graphql -f query='
    query($owner:String!,$name:String!,$pr:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          headRefOid
          commits(last: 100) {
            nodes {
              commit {
                oid
                authoredDate
                author { user { login } }
              }
            }
          }
          reviewThreads(first: 100) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              originalLine
              comments(first: 50) {
                nodes {
                  databaseId
                  author { login }
                  body
                  createdAt
                  originalCommit { oid }
                  url
                }
              }
            }
          }
        }
      }
    }' \
    -F owner="$OWNER" -F name="$NAME" -F pr="$pr_number") || {
    # Per-PR failure: log, track, continue. v1 has no persistence/
    # dedupe — silently dropping a PR's threads on transient failure
    # means missing triage signal that never recovers (the daily
    # window slides forward and the missed threads stay "resolved
    # without rationale" forever). Continue past this PR so the rest
    # of the day's data still surfaces, but record the failure so
    # the script can exit non-zero at the end and the workflow can
    # be retried via `workflow_dispatch` with the same --since/--until
    # to reconstruct the missing data. CodeRabbit Major r4 on PR #303.
    echo "daily-feedback-rollup: WARN gh api graphql failed for $REPO#$pr_number; threads NOT classified for this PR" >&2
    FAILED_PR_COUNT=$((FAILED_PR_COUNT + 1))
    FAILED_PR_LIST="${FAILED_PR_LIST:+$FAILED_PR_LIST,}$pr_number"
    continue
  }

  has_next=$(printf '%s' "$threads_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
  if [ "$has_next" = "true" ]; then
    echo "daily-feedback-rollup: WARN $REPO#$pr_number has >100 review threads; first page only" >&2
  fi

  # Per-PR commit map: SHA → authoredDate (for stale-HEAD detection +
  # touched-paths is needed at commit-detail level which the query
  # above doesn't include — we approximate via "any commit by an
  # agent author between comment.createdAt and thread.resolvedAt"
  # rather than per-file. Per-file is a documented v1 limitation in
  # the spec.)
  # (Currently unused — placeholder for future per-file fix detection.)

  thread_count=$(printf '%s' "$threads_json" | jq '.data.repository.pullRequest.reviewThreads.nodes | length // 0')

  j=0
  while [ "$j" -lt "$thread_count" ]; do
    t=$(printf '%s' "$threads_json" | jq -c ".data.repository.pullRequest.reviewThreads.nodes[$j]")
    j=$((j + 1))

    is_resolved=$(printf '%s' "$t" | jq -r '.isResolved')
    [ "$is_resolved" != "true" ] && continue

    # Only consider bot-authored original comments — agent-authored
    # top comments aren't bot review feedback. (The reply chain can
    # mix bot + agent; we look at the first comment for the original
    # finding.)
    original_author=$(printf '%s' "$t" | jq -r '.comments.nodes[0].author.login // "unknown"')
    case "$original_author" in
      coderabbitai\[bot\]|chatgpt-codex-connector\[bot\]) : ;;
      *) continue ;;
    esac

    thread_id=$(printf '%s' "$t" | jq -r '.id')
    thread_path=$(printf '%s' "$t" | jq -r '.path // ""')
    thread_line=$(printf '%s' "$t" | jq -r '.line // .originalLine // 0')
    thread_url=$(printf '%s' "$t" | jq -r '.comments.nodes[0].url // ""')
    original_body=$(printf '%s' "$t" | jq -r '.comments.nodes[0].body // ""')
    original_created=$(printf '%s' "$t" | jq -r '.comments.nodes[0].createdAt // ""')

    # Heuristic 1: tag in any agent-authored reply on this thread.
    # The reply with the canonical `[mergepath-resolve:<class>]`
    # marker takes precedence over the inferred class.
    tag_class=""
    reply_count=$(printf '%s' "$t" | jq '.comments.nodes | length')
    k=1
    while [ "$k" -lt "$reply_count" ]; do
      reply=$(printf '%s' "$t" | jq -c ".comments.nodes[$k]")
      reply_login=$(printf '%s' "$reply" | jq -r '.author.login // "unknown"')
      reply_body=$(printf '%s' "$reply" | jq -r '.body // ""')
      if is_agent_author "$reply_login"; then
        candidate=$(extract_tag_class "$reply_body")
        if [ -n "$candidate" ]; then
          tag_class="$candidate"
          break
        fi
      fi
      k=$((k + 1))
    done

    if [ -n "$tag_class" ]; then
      # Single-source the skip/surface decision through tag_class_action
      # (scripts/lib/daily-feedback-rollup-helpers.sh) so this path cannot
      # drift from the canonical taxonomy — the drift that previously omitted
      # templated-render here and re-filed routed templated threads as
      # deferred (#568, Codex P2 on #565). Unknown classes map to surface.
      if [ "$(tag_class_action "$tag_class")" = "skip" ]; then
        COUNT_TAGGED_SKIP=$((COUNT_TAGGED_SKIP + 1))
        continue
      else
        # surface (incl. unknown) → fall through to severity-routing below.
        COUNT_TAGGED_SURFACE=$((COUNT_TAGGED_SURFACE + 1))
      fi
    else
      # Heuristic 2: addressed-via-fix — any agent-author commit on
      # the PR with authoredDate > comment.createdAt. The spec's
      # per-file variant (commit must touch the comment's anchored
      # file) is more precise but requires a REST round-trip per
      # commit to fetch file lists; the GitHub GraphQL `Commit` type
      # doesn't expose changed files. The weaker per-PR heuristic
      # catches the codex P1 case ("resolved by follow-up commit, no
      # reply") but is conservative-toward-skip: an agent commit on
      # a DIFFERENT file in the same PR still marks this thread as
      # fix-addressed. The v2 agent-side
      # `[mergepath-resolve: addressed-elsewhere]` tagging closes
      # the gap more precisely than commit-introspection ever would.
      # (codex P1 r1 on PR #303.)
      addressed_via_fix=false
      commit_count=$(printf '%s' "$threads_json" | jq '.data.repository.pullRequest.commits.nodes | length')
      m=0
      while [ "$m" -lt "$commit_count" ]; do
        c_date=$(printf '%s' "$threads_json" | jq -r ".data.repository.pullRequest.commits.nodes[$m].commit.authoredDate // \"\"")
        c_login=$(printf '%s' "$threads_json" | jq -r ".data.repository.pullRequest.commits.nodes[$m].commit.author.user.login // \"\"")
        # String comparison works for ISO 8601 timestamps.
        if [ -n "$c_login" ] && [ -n "$c_date" ] && [ -n "$original_created" ] \
           && [ "$c_date" \> "$original_created" ] && is_agent_author "$c_login"; then
          addressed_via_fix=true
          break
        fi
        m=$((m + 1))
      done
      if $addressed_via_fix; then
        COUNT_FIX=$((COUNT_FIX + 1))
        continue
      fi

      # Heuristic 3: substantive reply from an agent author (≥30 chars,
      # NOT just the tag marker). If present, treat as addressed-via-
      # reply and skip.
      addressed_via_reply=false
      k=1
      while [ "$k" -lt "$reply_count" ]; do
        reply=$(printf '%s' "$t" | jq -c ".comments.nodes[$k]")
        reply_login=$(printf '%s' "$reply" | jq -r '.author.login // "unknown"')
        reply_body=$(printf '%s' "$reply" | jq -r '.body // ""')
        if is_agent_author "$reply_login"; then
          reply_len=${#reply_body}
          if [ "$reply_len" -ge 30 ]; then
            addressed_via_reply=true
            break
          fi
        fi
        k=$((k + 1))
      done
      if $addressed_via_reply; then
        COUNT_REPLY=$((COUNT_REPLY + 1))
        continue
      fi

      # Heuristic 4: thread is stale-head — its originalCommit isn't
      # in the PR's current commit history (got rebased away or force-
      # pushed off). Membership check against the commits list we
      # pulled in the GraphQL query (CodeRabbit Major r1 on PR #303
      # tightened the prior naive `orig_commit != head_oid` check).
      #
      # IMPORTANT: the GraphQL query pulls `commits(last: 100)`, which
      # is only the tail of the PR's history. On a PR with >100
      # commits, an older `originalCommit` can be in-history but
      # absent from this slice — we'd falsely classify as stale and
      # suppress a real deferred thread. Gate the stale-head branch
      # on `commit_count < 100` so we prefer surfacing over false-
      # skipping in the slice-saturated case (CodeRabbit Major r2 on
      # PR #303).
      orig_commit=$(printf '%s' "$t" | jq -r '.comments.nodes[0].originalCommit.oid // ""')
      if [ -n "$orig_commit" ] && [ "$commit_count" -lt 100 ]; then
        if ! printf '%s' "$threads_json" | jq -e --arg oid "$orig_commit" \
             '.data.repository.pullRequest.commits.nodes
              | any(.commit.oid == $oid)' >/dev/null; then
          COUNT_STALE=$((COUNT_STALE + 1))
          continue
        fi
      fi

      # No tag, no substantive reply, not stale → deferred-untagged.
      # SURFACE it (route by severity below).
      COUNT_DEFERRED_UNTAGGED=$((COUNT_DEFERRED_UNTAGGED + 1))
    fi

    # Severity → track.
    severity=$(classify_severity "$original_body")
    track=$(severity_to_track "$severity")

    # Item ID.
    item_id=$(item_id_for "${REPO}#${pr_number}:${thread_id}")

    # Body excerpt: first 200 chars, single-line, trimmed.
    body_excerpt_text=$(body_excerpt "$original_body")

    # Tag indicator for the rollup body (so triage knows whether the
    # agent recorded rationale or this is heuristic-fallback).
    if [ -n "$tag_class" ]; then
      tag_note="tagged: $tag_class"
    else
      tag_note="untagged — agent did not record rationale"
    fi

    item_json=$(jq -nc \
      --arg repo "$REPO" \
      --arg pr_number "$pr_number" \
      --arg pr_title "$pr_title" \
      --arg pr_url "$pr_url" \
      --arg pr_merged_at "$pr_merged_at" \
      --arg thread_id "$thread_id" \
      --arg thread_path "$thread_path" \
      --arg thread_line "$thread_line" \
      --arg thread_url "$thread_url" \
      --arg author "$original_author" \
      --arg severity "$severity" \
      --arg track "$track" \
      --arg body_excerpt "$body_excerpt_text" \
      --arg tag_note "$tag_note" \
      --arg item_id "$item_id" \
      '{
        repo:         $repo,
        pr_number:    $pr_number,
        pr_title:     $pr_title,
        pr_url:       $pr_url,
        pr_merged_at: $pr_merged_at,
        thread_id:    $thread_id,
        thread_path:  $thread_path,
        thread_line:  $thread_line,
        thread_url:   $thread_url,
        author:       $author,
        severity:     $severity,
        track:        $track,
        body_excerpt: $body_excerpt,
        tag_note:     $tag_note,
        item_id:      $item_id
      }')

    if [ "$track" = "substantive" ]; then
      printf '%s\n' "$item_json" >> "$SUBSTANTIVE_NDJSON"
    else
      printf '%s\n' "$item_json" >> "$POLISH_NDJSON"
    fi
  done
done

PRE_DEDUP_SUBSTANTIVE=$(wc -l < "$SUBSTANTIVE_NDJSON" | tr -d ' ')
PRE_DEDUP_POLISH=$(wc -l < "$POLISH_NDJSON" | tr -d ' ')

# ---------------------------------------------------------------------
# Step 2.5 — dedupe against prior rollups (mergepath#304)
# ---------------------------------------------------------------------
#
# Fetch open + recently-closed rollup issues (both tracks) within the
# 14-day window, parse the `<!-- mp-id:... -->` markers off each
# triaged line, and filter today's NDJSON streams to drop any mp-id
# already in the triaged set.
#
# Triage signals (per parse_triaged_ids_from_body in the helpers):
#   - `[x]` / `[X]`            → fix landed / won't-fix / followup-filed
#   - `[~]` / `[-]`            → N/A / not-relevant
#   - Strikethrough `~~...~~`  → preserves item visibility, excludes from re-list
#   - `#N` ref on same line    → follow-up issue filed
# Plus the implicit signal:
#   - Closed host issue        → ALL its items are triaged
#
# Cross-track scan: a substantive item triaged on a prior polish-track
# rollup also counts (and vice versa). Track-routing can flip across
# days as severity classification changes; the mp-id is the canonical
# identity, not the track. (Closes a foot-gun the spec didn't call
# out explicitly but is the natural read.)

TRIAGED_IDS_FILE=$(mktemp "${TMPDIR:-/tmp}/rollup-triaged-XXXXXX.ids")
# Rendered-body scratch file (#400): post_or_append writes the body here
# and passes --body-file, instead of --body "$body" (which hits ARG_MAX
# before the GitHub 65536 cap on a large body).
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/rollup-body-XXXXXX.md")
# Extend the EXIT trap to clean these up too.
trap 'rm -f "$SUBSTANTIVE_NDJSON" "$POLISH_NDJSON" "$TRIAGED_IDS_FILE" "$BODY_FILE"' EXIT

# Compute the dedupe-window cutoff. We pass it to `gh issue list` as
# `closed:>=YYYY-MM-DD` so the search server-side filters out stale
# closed rollups; open rollups aren't filtered (an open rollup is
# triage-active regardless of age — the cap is just protection
# against runaway label scopes).
if date -u -d "@0" '+%Y-%m-%d' >/dev/null 2>&1; then
  DEDUP_CUTOFF=$(date -u -d "${DEDUPE_WINDOW_DAYS} days ago" '+%Y-%m-%d')
else
  DEDUP_CUTOFF=$(date -u -v-"${DEDUPE_WINDOW_DAYS}"d '+%Y-%m-%d')
fi

# Fetch prior rollup issues for one label and append their triaged
# mp-ids to TRIAGED_IDS_FILE. Best-effort: on transient API failure,
# warn-and-continue rather than fail-closed — dedupe is an
# optimisation, not a correctness invariant. (The post-create
# atomicity gate above protects the all-or-nothing post path; the
# dedupe pass is read-only and additive.)
collect_triaged_ids_for_label() {
  local label="$1"
  local list_json
  # Search query: every issue with this label that's either open OR
  # closed within the dedupe window. The `is:issue` qualifier is
  # implicit for `gh issue list`. The label scope is the rollup
  # label; the `--search` filters by date.
  if ! list_json=$(gh issue list \
       --repo "$REPO" \
       --label "$label" \
       --state all \
       --search "is:issue label:$label closed:>=$DEDUP_CUTOFF" \
       --limit "$MAX_PRIOR_ROLLUPS_PER_LABEL" \
       --json number,state,body,comments 2>/dev/null); then
    echo "daily-feedback-rollup: WARN dedupe: could not list prior '$label' rollups (best-effort, continuing)" >&2
    DEDUP_FETCH_FAILURES=$((DEDUP_FETCH_FAILURES + 1))
    return 0
  fi
  # Also fold in OPEN rollups (no date filter — open = live triage
  # surface regardless of age). The earlier `gh issue list` with the
  # `closed:>=` search excludes open issues (the search clause
  # `closed:` doesn't match open ones), so we do a second pass.
  local open_json
  if ! open_json=$(gh issue list \
       --repo "$REPO" \
       --label "$label" \
       --state open \
       --limit "$MAX_PRIOR_ROLLUPS_PER_LABEL" \
       --json number,state,body,comments 2>/dev/null); then
    echo "daily-feedback-rollup: WARN dedupe: could not list open '$label' rollups (best-effort, continuing)" >&2
    DEDUP_FETCH_FAILURES=$((DEDUP_FETCH_FAILURES + 1))
    open_json='[]'
  fi
  # Merge the two arrays, de-dupe on issue number (an open issue
  # showing up only in `open_json`, a closed-in-window issue only in
  # `list_json` — no overlap in normal cases, but unique just in
  # case the search query semantics drift).
  local merged
  merged=$(jq -s '
    (.[0] // []) + (.[1] // [])
    | unique_by(.number)
  ' <(printf '%s' "$list_json") <(printf '%s' "$open_json"))

  local n
  n=$(printf '%s' "$merged" | jq 'length')
  local x=0
  while [ "$x" -lt "$n" ]; do
    local issue_state issue_num issue_body inline_comment_count comment_text issue_text
    issue_state=$(printf '%s' "$merged" | jq -r ".[$x].state")
    issue_num=$(printf '%s' "$merged" | jq -r ".[$x].number")
    issue_body=$(printf '%s' "$merged" | jq -r ".[$x].body // \"\"")
    inline_comment_count=$(printf '%s' "$merged" | jq -r ".[$x].comments // [] | length")
    # Parse the BODY *and* all comment bodies (#402). The throttle path
    # appends today's findings as a COMMENT (append-only, atomic — we keep
    # that rather than a read-modify-write body edit that could clobber a
    # concurrent run). The inline `comments` list field is page-capped
    # (~100, #403), so when an issue has any comments we paginate the REST
    # endpoint to read EVERY one — otherwise a rollup with >100 appended
    # comments would lose dedupe visibility for the later mp-ids. The
    # inline count is only a cheap "are there comments?" gate so the
    # common (0-comment) rollup skips the extra call.
    comment_text=""
    if [ "$inline_comment_count" -gt 0 ]; then
      if ! comment_text=$(gh api --paginate \
           "repos/$OWNER/$NAME/issues/$issue_num/comments" \
           --jq '.[].body // empty' 2>/dev/null); then
        echo "daily-feedback-rollup: WARN dedupe: could not paginate comments for #$issue_num (best-effort, continuing)" >&2
        DEDUP_FETCH_FAILURES=$((DEDUP_FETCH_FAILURES + 1))
        comment_text=""
      fi
    fi
    issue_text="${issue_body}
${comment_text}"
    if [ "$issue_state" = "CLOSED" ] || [ "$issue_state" = "closed" ]; then
      # Closed host → ALL mp-ids on this rollup (body + comments) are
      # implicitly triaged.
      parse_all_ids_from_body "$issue_text" >> "$TRIAGED_IDS_FILE"
    else
      # Open host → only lines with an explicit triage signal count,
      # whether they sit in the body or an appended comment.
      parse_triaged_ids_from_body "$issue_text" >> "$TRIAGED_IDS_FILE"
    fi
    x=$((x + 1))
  done
}

# Scan BOTH track labels. mp-ids are track-agnostic so cross-track
# triage signals must apply.
collect_triaged_ids_for_label "$SUBSTANTIVE_LABEL"
collect_triaged_ids_for_label "$POLISH_LABEL"

# De-dupe the triaged set (a single mp-id can appear on multiple
# prior rollups via the throttling-append path).
if [ -s "$TRIAGED_IDS_FILE" ]; then
  sort -u "$TRIAGED_IDS_FILE" -o "$TRIAGED_IDS_FILE"
fi
TRIAGED_ID_COUNT=$(wc -l < "$TRIAGED_IDS_FILE" | tr -d ' ')
echo "daily-feedback-rollup: dedupe: ${TRIAGED_ID_COUNT} prior-triaged mp-id(s) in 14-day window (window from ${DEDUP_CUTOFF})" >&2

# Filter both NDJSON streams against TRIAGED_IDS_FILE. Track skipped
# count per stream and update COUNT_DEDUP_SKIPPED.
filter_ndjson_against_triaged() {
  local stream="$1"
  if [ ! -s "$stream" ] || [ ! -s "$TRIAGED_IDS_FILE" ]; then
    return 0
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/rollup-filter-XXXXXX.ndjson")
  local pre post
  pre=$(wc -l < "$stream" | tr -d ' ')
  # jq -R reads raw text. Slurp the triaged IDs into a set, then
  # filter each NDJSON line. We use a single jq invocation per stream
  # rather than a per-line shell loop (10x faster on real-world
  # rollups with >50 items).
  if ! jq -R -s '
    split("\n") | map(select(length > 0)) | reduce .[] as $id ({}; . + {($id): true})
  ' < "$TRIAGED_IDS_FILE" > "$tmp.set"; then
    echo "daily-feedback-rollup: ERROR — failed to build dedupe set from $TRIAGED_IDS_FILE" >&2
    rm -f "$tmp.set" "$tmp"
    exit 2
  fi

  # No `|| true` here: jq failure (parse error, runtime fault, bad
  # NDJSON line) would silently truncate the stream and the dedupe
  # filter would over-skip — contradicting the script's silent-data-
  # loss-prevention contract (CodeRabbit Major r1 on PR #307). Fail-
  # closed instead: exit 2 with a clean diagnostic, leaving the temp
  # files trapped for cleanup by the EXIT trap. The operator's retry
  # path is identical to the per-PR-fetch failure case above.
  if ! jq -c --slurpfile triagedSet "$tmp.set" '
    select(.item_id as $id | ($triagedSet[0][$id] // false) | not)
  ' < "$stream" > "$tmp.out"; then
    echo "daily-feedback-rollup: ERROR — dedupe filter failed while processing $stream (jq runtime error?)" >&2
    rm -f "$tmp.set" "$tmp.out" "$tmp"
    exit 2
  fi

  mv "$tmp.out" "$stream"
  rm -f "$tmp.set" "$tmp"
  post=$(wc -l < "$stream" | tr -d ' ')
  local skipped=$((pre - post))
  COUNT_DEDUP_SKIPPED=$((COUNT_DEDUP_SKIPPED + skipped))
}

filter_ndjson_against_triaged "$SUBSTANTIVE_NDJSON"
filter_ndjson_against_triaged "$POLISH_NDJSON"

SUBSTANTIVE_COUNT=$(wc -l < "$SUBSTANTIVE_NDJSON" | tr -d ' ')
POLISH_COUNT=$(wc -l < "$POLISH_NDJSON" | tr -d ' ')

echo "daily-feedback-rollup: classified substantive=$SUBSTANTIVE_COUNT polish=$POLISH_COUNT" \
     "(skipped fix=$COUNT_FIX reply=$COUNT_REPLY stale=$COUNT_STALE tagged-skip=$COUNT_TAGGED_SKIP dedup=$COUNT_DEDUP_SKIPPED)" \
     "(pre-dedupe substantive=$PRE_DEDUP_SUBSTANTIVE polish=$PRE_DEDUP_POLISH)" >&2

# ---------------------------------------------------------------------
# Dry-run short-circuit
# ---------------------------------------------------------------------

if $DRY_RUN; then
  echo "daily-feedback-rollup: --dry-run → emitting NDJSON to stdout, no issue mutation" >&2
  if [ -s "$SUBSTANTIVE_NDJSON" ]; then
    cat "$SUBSTANTIVE_NDJSON"
  fi
  if [ -s "$POLISH_NDJSON" ]; then
    cat "$POLISH_NDJSON"
  fi
  # Dry-run still surfaces per-PR failures via exit code so the
  # operator inspecting `--dry-run` output sees the same "this run
  # is incomplete" signal a non-dry run would emit.
  if [ "$FAILED_PR_COUNT" -gt 0 ]; then
    echo "daily-feedback-rollup: WARN — $FAILED_PR_COUNT PR(s) failed to fetch threads in this dry run (PRs: $FAILED_PR_LIST)." >&2
    exit 2
  fi
  exit 0
fi

# ---------------------------------------------------------------------
# Atomicity gate — abort BEFORE posting if any per-PR fetch failed.
# ---------------------------------------------------------------------
#
# Posting partial rollups and then exiting 2 is worse than not posting
# at all: with v1 dedupe-against-prior-rollups deferred, the operator's
# retry on the same --since/--until window would create a duplicate
# (or overlapping) rollup issue, doubling triage cost. Total atomicity
# — either all-or-nothing — keeps the rollup-output contract intact.
#
# The operator's recovery path: retry the same `workflow_dispatch
# --since X --until X` invocation once the API recovers. The classifier
# is stateless and idempotent w.r.t. inputs, so the retry produces
# the complete window's data exactly once.
#
# (codex Phase 4b r2 on PR #303.)
if [ "$FAILED_PR_COUNT" -gt 0 ]; then
  echo "daily-feedback-rollup: ERROR — $FAILED_PR_COUNT PR(s) failed to fetch threads (PRs: $FAILED_PR_LIST)." >&2
  echo "daily-feedback-rollup: Aborting WITHOUT posting any rollup issues. Re-run with the same --since/--until once the API recovers to produce a complete rollup." >&2
  exit 2
fi

# ---------------------------------------------------------------------
# Step 3 — render and post per-track issues
# ---------------------------------------------------------------------

render_rollup_body() {
  local ndjson_file="$1" track="$2"
  local f="$ndjson_file"
  # Render EVERY finding into the body (#401): top-N highest-severity
  # inline with full detail, the rest in a collapsed <details> overflow
  # block. Overflow detail degrades rich -> mp-id stub to fit
  # ROLLUP_BODY_BUDGET; if even stubs won't fit we return 2 (fail loud,
  # no partial post) so the caller aborts rather than silently dropping
  # findings the per-day window will never re-enumerate. All logic stays
  # INSIDE this function so the test's sed-extraction stays whole.
  local total
  total=$(wc -l < "$f" | tr -d ' ')

  local rb
  rb=$(mktemp -d "${TMPDIR:-/tmp}/rollup-render-XXXXXX")

  cat > "$rb/intro.md" <<INTRO
Auto-generated rollup of bot review threads that were resolved on
${DATE_STAMP} without an associated fix commit or substantive reply.
Severity scope: ${track} (see § Two-track rollup in #299 for the
routing rule).

Triage markers (set on the checkbox below):
- \`[ ]\` open / not yet triaged
- \`[x]\` fix landed, won't-fix accepted, or follow-up issue filed
- \`[~]\` N/A — not relevant

INTRO

  cat > "$rb/footer.md" <<FOOTER

---

<details>
<summary>Methodology</summary>

- Window: ${SINCE} — ${UNTIL}
- PRs scanned: ${pr_count}
- Threads classified:
  - addressed-via-fix (heuristic, per-PR): ${COUNT_FIX}
  - addressed-via-reply (heuristic): ${COUNT_REPLY}
  - stale-head (heuristic): ${COUNT_STALE}
  - tagged-skip: ${COUNT_TAGGED_SKIP}
  - tagged-surface: ${COUNT_TAGGED_SURFACE}
  - deferred-untagged (heuristic): ${COUNT_DEFERRED_UNTAGGED}
- Dedupe pass (#304): ${COUNT_DEDUP_SKIPPED} item(s) previously triaged on prior rollups in the ${DEDUPE_WINDOW_DAYS}-day window (since ${DEDUP_CUTOFF})

Generator: \`scripts/daily-feedback-rollup.sh\` (mergepath#299 v1 + #304 dedupe + #401 overflow)
</details>
FOOTER

  # Severity-major sort (P0 first), one JSON per line. Top-N render inline
  # with full detail; the rest are the overflow tail.
  jq -s -c '
    def sevrank:
      (.severity // "Unknown") as $s |
      if   $s == "P0"      then 0 elif $s == "P1"      then 1
      elif $s == "P2"      then 2 elif $s == "Major"   then 3
      elif $s == "Minor"   then 4 elif $s == "P3"      then 5
      elif $s == "Nitpick" then 6 elif $s == "Trivial" then 7
      else 8 end;
    sort_by(sevrank * 1000000 + ((.pr_number | tonumber?) // 0)) | .[]
  ' "$f" > "$rb/sorted.ndjson"
  head -n "$ROLLUP_MAX_VISIBLE" "$rb/sorted.ndjson" > "$rb/top.ndjson"
  tail -n "+$((ROLLUP_MAX_VISIBLE + 1))" "$rb/sorted.ndjson" > "$rb/over.ndjson" 2>/dev/null || : > "$rb/over.ndjson"
  local overflow_count
  overflow_count=$(wc -l < "$rb/over.ndjson" | tr -d ' ')

  # Inline top-N (full detail). Byte-identical to the pre-#400 line format
  # so unchecked_count_on() and the mp-id parsers still match.
  jq -s -r '
    group_by(.pr_number)[] |
    "## " + .[0].repo + "#" + .[0].pr_number +
      " (merged " + (.[0].pr_merged_at // "n/a") + ", " +
      (.[0].pr_title | tostring) + ")\n" +
    (map(
      "- [ ] [" + .thread_path + ":" + .thread_line + "](" + .thread_url + ")" +
      " — `" + .author + "` " + .severity +
      " [" + .tag_note + "]: \"" + .body_excerpt + "\"" +
      " <!-- mp-id:" + .item_id + " -->"
    ) | join("\n"))
  ' "$rb/top.ndjson" > "$rb/inline.md"

  # Overflow renderings (tried rich -> stub until the body fits). Both
  # keep an OPEN `- [ ]` + the exact `<!-- mp-id:ID -->` marker and carry
  # NO triage signal: the mp-id sits alone on its bullet line; any `#NUM`
  # appears only on a `###` header line (rich), never adjacent to a
  # boundary char, so parse_triaged_ids_from_body never mis-reads it.
  jq -s -r '
    group_by(.pr_number)[] |
    "### " + .[0].repo + "#" + .[0].pr_number + " (merged " + (.[0].pr_merged_at // "n/a") + ")\n" +
    (map(
      "- [ ] [" + .thread_path + ":" + .thread_line + "](" + .thread_url + ")" +
      " — `" + .author + "` " + .severity +
      " <!-- mp-id:" + .item_id + " -->"
    ) | join("\n"))
  ' "$rb/over.ndjson" > "$rb/over-rich.md"
  jq -r '"- [ ] <!-- mp-id:" + .item_id + " -->"' "$rb/over.ndjson" > "$rb/over-stub.md"

  local mode chosen=""
  for mode in rich stub; do
    {
      cat "$rb/intro.md"
      cat "$rb/inline.md"
      if [ "$overflow_count" -gt 0 ]; then
        printf '\n<details>\n<summary>+%s more finding(s) — full set retained below. NOTE: closing this issue marks ALL of these (including the collapsed overflow) as triaged.</summary>\n\n' "$overflow_count"
        cat "$rb/over-$mode.md"
        printf '\n</details>\n'
      fi
      cat "$rb/footer.md"
    } > "$rb/body-$mode.md"
    if [ "$(wc -c < "$rb/body-$mode.md" | tr -d ' ')" -le "$ROLLUP_BODY_BUDGET" ]; then
      chosen="$rb/body-$mode.md"
      break
    fi
  done

  if [ -n "$chosen" ]; then
    cat "$chosen"
    rm -rf "$rb"
    return 0
  fi
  rm -rf "$rb"
  echo "daily-feedback-rollup: $track — FATAL: $total findings exceed single-issue capacity (${ROLLUP_BODY_BUDGET}B) even as mp-id stubs; refusing to post a partial rollup that would silently drop findings the per-day window will not re-enumerate. Narrow the window (--since/--until) or split the backlog." >&2
  return 2
}

# Self-throttling: count unchecked items on the most recently-opened
# rollup issue with the track's label. If ≥ threshold, append today's
# items as a comment instead of opening a new issue.
unchecked_count_on() {
  # POSIX character classes — `\s` is GNU-grep-specific and not part
  # of POSIX ERE. The ubuntu-latest runner has GNU grep but the
  # downstream propagation path may not, and consistency with the
  # rest of the codebase (which uses `[[:space:]]`) keeps the
  # check_mktemp_portability-style regex audits happy
  # (CodeRabbit Major r1 on PR #303).
  #
  # Fail-closed on API errors: if `gh issue view` fails, abort the
  # run with exit 2 rather than treating "couldn't read" as
  # "0 unchecked items." The latter would skip throttling and
  # potentially create a duplicate rollup issue, which is a worse
  # operator experience than a clean failure. CodeRabbit Major r4
  # on PR #303.
  local issue_number="$1"
  local body
  if ! body=$(gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body'); then
    echo "daily-feedback-rollup: ERROR — could not read body of issue #$issue_number for throttle check; aborting rather than risk a duplicate rollup" >&2
    exit 2
  fi
  # `grep -c` returns 1 when no matches found, which under set -e is
  # propagated. `|| true` here is the no-match case, NOT an error-
  # suppression — the API call already succeeded above.
  printf '%s' "$body" \
    | grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]' || true
}

most_recent_open_rollup() {
  # Fail-closed: a `gh issue list` failure that gets swallowed as
  # "no existing rollup" would create a duplicate rollup issue on
  # transient API errors. Exit 2 instead. CodeRabbit Major r4 on PR
  # #303.
  local label="$1"
  local out
  if ! out=$(gh issue list --repo "$REPO" --state open --label "$label" \
       --limit 1 --json number,title --jq '.[0].number // ""'); then
    echo "daily-feedback-rollup: ERROR — could not list existing '$label' rollup issues for throttle check; aborting rather than risk a duplicate rollup" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# Idempotently create the track label if it doesn't already exist in
# the repo, so the first rollup run on a fresh consumer doesn't fail
# at `gh issue create --label`. `gh label create --force` updates
# color/description in place when the label already exists and
# creates it otherwise (the helper survives consumer label-policy
# drift). Failure here is logged + swallowed: if label-creation
# fails for some reason (permissions, transient API), the downstream
# `gh issue create --label` will surface the real diagnostic.
#
# Closes nathanpayne-codex Phase 4b r1 on PR #303 — the live repo
# had neither `deferred-feedback-rollup` nor `polish-feedback-rollup`
# defined, so the workflow would have errored the first time it had
# feedback to file.
ensure_label() {
  local name="$1" track="$2"
  local color description
  case "$track" in
    substantive)
      color="d73a4a"
      description="Daily rollup of deferred bot review feedback — substantive scope (CodeRabbit Major / Codex P0-P2). Triage within a few days. See #299."
      ;;
    polish)
      color="0e8a16"
      description="Daily rollup of deferred bot review feedback — polish scope (CodeRabbit Nitpick/Trivial / Codex P3). Batch triage; low urgency. See #299."
      ;;
    *)
      color="ededed"
      description="Daily deferred-feedback rollup (#299)."
      ;;
  esac
  if ! gh label create "$name" \
       --repo "$REPO" \
       --color "$color" \
       --description "$description" \
       --force >/dev/null 2>&1; then
    echo "daily-feedback-rollup: WARN — could not ensure label '$name' (will let gh issue create surface the real error)" >&2
  fi
}

post_or_append() {
  local ndjson_file="$1" track="$2" label="$3" throttle="$4" title="$5"
  if [ ! -s "$ndjson_file" ]; then
    echo "daily-feedback-rollup: $track — no items to surface today" >&2
    return 0
  fi

  # Self-bootstrap: ensure the track label exists before we either
  # comment on an existing issue (no label change there, but the
  # `--label` query above could miss new labels for the same reason)
  # or create a new one. Runs ONLY in the mutation path so
  # `--dry-run` stays a pure read.
  ensure_label "$label" "$track"

  # Render to a file and post via --body-file (#400): --body "$body"
  # caps out at ARG_MAX on a large rollup, below GitHub's 65536 limit.
  # render_rollup_body returns 2 (fail loud, no partial body) if even
  # mp-id stubs exceed the body budget — abort rather than post a rollup
  # that silently drops findings the per-day window won't re-enumerate.
  if ! render_rollup_body "$ndjson_file" "$track" > "$BODY_FILE"; then
    echo "daily-feedback-rollup: $track — ABORTING: rollup body exceeds the size budget even as stubs (see FATAL above); not posting a partial rollup." >&2
    exit 2
  fi

  local existing=""
  # No `|| true` here: most_recent_open_rollup now fails-closed (exit 2)
  # on API errors. The empty-string return value is a legitimate
  # "no existing rollup found" signal (no label matches yet).
  existing=$(most_recent_open_rollup "$label")

  if [ -n "$existing" ]; then
    local unchecked
    unchecked=$(unchecked_count_on "$existing")
    if [ "$unchecked" -ge "$throttle" ]; then
      echo "daily-feedback-rollup: $track — appending to existing #$existing ($unchecked unchecked ≥ throttle $throttle)" >&2
      gh issue comment "$existing" --repo "$REPO" --body-file "$BODY_FILE" >&2
      return 0
    fi
  fi

  echo "daily-feedback-rollup: $track — creating new issue '$title'" >&2
  gh issue create --repo "$REPO" --title "$title" --label "$label" --body-file "$BODY_FILE"
}

post_or_append "$SUBSTANTIVE_NDJSON" "substantive" "$SUBSTANTIVE_LABEL" \
  "$SUBSTANTIVE_THROTTLE" "${SUBSTANTIVE_LABEL} ${DATE_STAMP}"
post_or_append "$POLISH_NDJSON" "polish" "$POLISH_LABEL" \
  "$POLISH_THROTTLE" "${POLISH_LABEL} ${DATE_STAMP}"

# Note: the FAILED_PR_COUNT check happens BEFORE post_or_append in
# the atomicity gate above (codex Phase 4b r2 on PR #303). By the
# time we reach this point, the run has either successfully posted
# both tracks' rollups or short-circuited via dry-run.
echo "daily-feedback-rollup: done" >&2
