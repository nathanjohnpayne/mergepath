#!/usr/bin/env bash
# late-codex-findings.sh — surface Codex findings that land after a PR merged
# (#2881).
#
# Nothing can block a finding that arrives after the merge. The merge gate's
# bounded wait for a requested Codex review (codex-review-check.sh, #2881
# option (c)) ends in an explicit timed-out/substitute-used fallback, and a
# review that is still running then can report after merge. Codex also posts
# findings as a plain issue comment with no companion review: mergepath#1120
# got a P2 that way five minutes after merge (issuecomment-5447842730). This
# script turns each such finding into a durable, visible follow-up instead of
# a log line.
#
# Usage:
#   late-codex-findings.sh --repo OWNER/REPO --pr N [--touched review:<id>] [--dry-run]
#   late-codex-findings.sh --repo OWNER/REPO --sweep [--since ISO-8601] [--dry-run]
#   late-codex-findings.sh --select [--touched review:<id>] < {merged_at, comments, reviews, inline}
#     (the pure selector alone, for tests; prints the findings JSON)
#
# A finding qualifies when all of these hold:
#   - the configured Codex App bot wrote it (login match; a present user.type
#     must be `Bot`), and it is not the Review Summary;
#   - it carries a priority marker: a `![Pn Badge]` image, or a `[Pn]` heading
#     or bold label, n in 0-3 (the review, inline and cloud-task formats);
#   - it was created or last edited strictly after the PR's merged_at, so an
#     edit that adds findings after merge counts as well as a new comment. The
#     REST review object has no edit time, so a review's edit time comes from
#     GraphQL `PullRequestReview.lastEditedAt`; that lets the sweep recover a
#     pre-merge review edited after merge even when the event run could not
#     write (a fork PR's read-only token). `--touched review:<id>` (the
#     edited-review event) also marks that review as changed now.
# Each finding is keyed by kind, id and a fingerprint of its current body. An
# edit that changes the body is a new item; a repeat delivery of the same body
# is not.
#
# Follow-up: one tracking issue per merged PR, labelled `late-codex-finding`
# and identified by the body marker
#   <!-- mergepath-late-codex-finding: OWNER/REPO#N -->
# A new item is appended as a comment carrying
#   <!-- mergepath-late-codex-item: <kind>:<id>:<fingerprint> -->
# and a closed tracking issue is reopened. Items already recorded anywhere in
# the issue are skipped, so reruns and the daily sweep do not duplicate them.
# The workflow serialises runs per PR; two writers in the same instant (an
# event run and the sweep) can still record one item twice. That costs a
# duplicate comment, never a missed finding.
#
# --sweep re-reads every PR closed and updated since --since (default: two
# days ago), which covers missed events and fork PRs whose event token is
# read-only.
#
# Exit codes: 0 done (including nothing to report), 2 usage/config, 3 a
# GitHub read or write failed.
set -euo pipefail

REPO=""
PR=""
SWEEP=0
SINCE=""
TOUCHED=""
DRY_RUN=0
SELECT=0
BOT="${LATE_CODEX_BOT_LOGIN:-chatgpt-codex-connector[bot]}"
LABEL="late-codex-finding"

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --sweep) SWEEP=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --touched) TOUCHED="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --select) SELECT=1; shift ;;
    -h|--help) usage ;;
    *) echo "late-codex-findings: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ "$TOUCHED" =~ ^(review:[1-9][0-9]*)?$ ]] || { echo "late-codex-findings: --touched must be review:<id>" >&2; exit 2; }
[ "$SELECT" = 1 ] || [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "late-codex-findings: --repo OWNER/REPO is required" >&2; exit 2; }
if [ "$SWEEP" = 1 ]; then
  [ -z "$PR" ] || { echo "late-codex-findings: --pr and --sweep are exclusive" >&2; exit 2; }
  if [ -z "$SINCE" ]; then
    SINCE=$(date -u -r $(( $(date -u +%s) - 172800 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
  fi
  [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "late-codex-findings: --since must be YYYY-MM-DDTHH:MM:SSZ" >&2; exit 2; }
elif [ "$SELECT" = 0 ]; then
  [[ "$PR" =~ ^[1-9][0-9]*$ ]] || { echo "late-codex-findings: --pr N (positive integer) or --sweep is required" >&2; exit 2; }
fi

read_array() { # endpoint -> flattened JSON array, or exit 3
  local out
  out=$(gh api --paginate "$1" 2>/dev/null | jq -cs 'add // []' 2>/dev/null) \
    && printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { echo "late-codex-findings: cannot read $1" >&2; exit 3; }
  printf '%s' "$out"
}

# Pure: the findings a merged PR received after merge, as
# [{key, kind, id, url, changed_at, tiers, minutes}], oldest first.
# Exposed for tests as `late-codex-findings.sh --select` on stdin; that output
# keeps each item's body, which the writer below drops after fingerprinting.
select_late_findings() { # stdin: {merged_at, comments, reviews, inline}; $1 bot, $2 touched review id
  jq -c --arg bot "$1" --arg touched "${2:-}" '
    def secs: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
              then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) else null end;
    def is_bot: (.user.login // "") == $bot and $bot != "" and ((.user.type // "Bot") == "Bot");
    def marked: (.body // "") | test("!\\[P[0-3] Badge\\]|(?m)^[[:space:]]*(#{1,6}[[:space:]]*|\\*\\*)\\[P[0-3]\\]");
    def tiers: [ (.body // "") | scan("!\\[(P[0-3]) Badge\\]|\\[(P[0-3])\\]") | map(select(. != null)) | .[0] ] | unique;
    def item($kind; $changed):
      { kind: $kind, id: .id, url: (.html_url // ""), changed_at: $changed,
        tiers: tiers, body: (.body // "") };
    (.merged_at | secs) as $merged
    | if $merged == null then error("merged_at unreadable") else . end
    | [ (.comments[] | select(is_bot and marked)
           | select((.body // "") | startswith("<!-- codex-pull-request-review-summary -->") | not)
           | ([.created_at, .updated_at] | map(select(. != null)) | max) as $c
           | select(($c | secs) != null and ($c | secs) > $merged)
           | item("issue-comment"; $c)),
        (.reviews[] | select(is_bot and marked)
           | ([.submitted_at, .edited_at] | map(select(. != null)) | max) as $c
           | select((($c | secs) // 0) > $merged or ((.id | tostring) == $touched and $touched != ""))
           | item("review"; (if (($c | secs) // 0) > $merged then $c else "edited-after-merge" end))),
        (.inline[] | select(is_bot and marked)
           | ([.created_at, .updated_at] | map(select(. != null)) | max) as $c
           | select(($c | secs) != null and ($c | secs) > $merged)
           | item("inline-comment"; $c)) ]
    | map(. + { minutes: (if (.changed_at | secs) == null then null
                          else (((.changed_at | secs) - $merged) / 60 | floor) end) })
    | sort_by(.changed_at, .kind, .id)'
}

fingerprint() { # stdin body -> 16 hex
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16; else shasum -a 256 | cut -c1-16; fi
}

if [ "$SELECT" = 1 ]; then
  select_late_findings "$BOT" "${TOUCHED#review:}"
  exit $?
fi

process_pr() { # pr
  local pr="$1" meta merged_at comments reviews inline items keyed issues issue existing new_items body num state
  meta=$(gh api "repos/$REPO/pulls/$pr" 2>/dev/null) || { echo "late-codex-findings: cannot read $REPO#$pr" >&2; exit 3; }
  merged_at=$(printf '%s' "$meta" | jq -r '.merged_at // ""')
  if [ -z "$merged_at" ]; then
    echo "late-codex-findings: $REPO#$pr is not merged; nothing to do"
    return 0
  fi
  comments=$(read_array "repos/$REPO/issues/$pr/comments?per_page=100")
  reviews=$(read_array "repos/$REPO/pulls/$pr/reviews?per_page=100")
  # Review edit times are GraphQL-only. Paginated; unreadable fails the PR.
  edits=$(gh api graphql --paginate -F pr="$pr" -f owner="${REPO%/*}" -f name="${REPO#*/}" -f query='
    query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
        reviews(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { databaseId lastEditedAt } } } } }' 2>/dev/null \
    | jq -cs '[ .[].data.repository.pullRequest.reviews.nodes[] ]' 2>/dev/null) \
    && printf '%s' "$edits" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { echo "late-codex-findings: cannot read review edit times on $REPO#$pr" >&2; exit 3; }
  reviews=$(printf '%s\n%s\n' "$reviews" "$edits" | jq -cs '
    (.[1] | map({key: (.databaseId | tostring), value: .lastEditedAt}) | from_entries) as $e
    | .[0] | map(. + {edited_at: $e[(.id | tostring)]})')
  inline=$(read_array "repos/$REPO/pulls/$pr/comments?per_page=100")
  items=$(printf '%s\n%s\n%s\n' "$comments" "$reviews" "$inline" \
    | jq -cs --arg m "$merged_at" '{merged_at: $m, comments: .[0], reviews: .[1], inline: .[2]}' \
    | select_late_findings "$BOT" "${TOUCHED#review:}") || { echo "late-codex-findings: cannot select findings on $REPO#$pr" >&2; exit 3; }
  if [ "$(printf '%s' "$items" | jq 'length')" = 0 ]; then
    echo "late-codex-findings: $REPO#$pr has no Codex finding after merge ($merged_at)"
    return 0
  fi
  # Key each item by its current body, so an edit is a new item.
  keyed='[]'
  while IFS= read -r it; do
    fp=$(printf '%s' "$it" | jq -j '.body' | fingerprint)
    keyed=$(printf '%s\n%s\n' "$keyed" "$it" | jq -cs --arg fp "$fp" '.[0] + [.[1] + {key: "\(.[1].kind):\(.[1].id):\($fp)"} | del(.body)]')
  done < <(printf '%s' "$items" | jq -c '.[]')

  issues=$(read_array "repos/$REPO/issues?labels=$LABEL&state=all&per_page=100")
  issue=$(printf '%s' "$issues" | jq -c --arg marker "<!-- mergepath-late-codex-finding: $REPO#$pr -->" \
    '[ .[] | select(.pull_request == null) | select((.body // "") | contains($marker)) ] | min_by(.number) // null')
  existing='[]'
  if [ "$issue" != null ]; then
    num=$(printf '%s' "$issue" | jq -r .number)
    existing=$( { printf '%s' "$issue" | jq -c '[.body // ""]'; read_array "repos/$REPO/issues/$num/comments?per_page=100" | jq -c '[.[].body // ""]'; } \
      | jq -cs 'add | [ .[] | scan("<!-- mergepath-late-codex-item: ([^ ]+) -->") | .[0] ] | unique')
  fi
  new_items=$(printf '%s\n%s\n' "$keyed" "$existing" | jq -cs '.[1] as $seen | [ .[0][] | select(.key as $k | $seen | index($k) | not) ]')
  if [ "$(printf '%s' "$new_items" | jq 'length')" = 0 ]; then
    echo "late-codex-findings: every late Codex finding on $REPO#$pr is already recorded"
    return 0
  fi
  body=$(printf '%s' "$new_items" | jq -r --arg pr "$pr" --arg merged "$merged_at" '
    map("- [\(.kind) \(.id)](\(.url)): \(if (.tiers | length) > 0 then (.tiers | join(", ")) else "priority marker" end), changed \(.changed_at)\(if .minutes != null then " (\(.minutes) min after merge)" else "" end) <!-- mergepath-late-codex-item: \(.key) -->")
    | join("\n")')
  if [ "$DRY_RUN" = 1 ]; then
    echo "late-codex-findings: dry run, would record on $REPO#$pr:"
    printf '%s\n' "$body"
    return 0
  fi
  if [ "$issue" = null ]; then
    gh api -X POST "repos/$REPO/labels" -f name="$LABEL" -f color=d93f0b \
      -f description="Codex reported findings after the PR merged (nathanjohnpayne/mergepath#2881)" >/dev/null 2>&1 || true
    jq -n --arg repo "$REPO" --arg pr "$pr" --arg merged "$merged_at" --arg items "$body" --arg label "$LABEL" '{
      title: "Late Codex findings on merged PR #\($pr)",
      labels: [$label],
      body: ("<!-- mergepath-late-codex-finding: \($repo)#\($pr) -->\n"
        + "Codex reported findings on #\($pr) after it merged at \($merged). No merge gate can block a finding that arrives after the merge, so each one is recorded here for triage (nathanjohnpayne/mergepath#2881).\n\n"
        + "This can follow a `timed-out/substitute-used` merge, where the gate stopped waiting for a requested Codex review and accepted the independent Phase 4b approval, or a findings comment Codex posted late. Triage each item: fix it in a follow-up PR, or record why it needs no change, then close this issue. A later finding on the same PR reopens it.\n\n"
        + $items + "\n")}' >"${TMPDIR:-/tmp}/late-codex-findings.$$.json"
    gh api -X POST "repos/$REPO/issues" --input "${TMPDIR:-/tmp}/late-codex-findings.$$.json" --jq .html_url \
      || { rm -f "${TMPDIR:-/tmp}/late-codex-findings.$$.json"; echo "late-codex-findings: cannot create the tracking issue for $REPO#$pr" >&2; exit 3; }
    rm -f "${TMPDIR:-/tmp}/late-codex-findings.$$.json"
  else
    state=$(printf '%s' "$issue" | jq -r .state)
    # Reopen BEFORE recording the item: the item marker is what makes a rerun
    # skip it, so a reopen that failed after the comment landed would never be
    # retried and the finding would sit on a closed issue (Codex P2 on #2886).
    # A failed comment after a successful reopen is retried by the next run.
    if [ "$state" = closed ]; then
      gh api -X PATCH "repos/$REPO/issues/$num" -f state=open >/dev/null \
        || { echo "late-codex-findings: cannot reopen #$num; the finding is not recorded, so the next run retries" >&2; exit 3; }
    fi
    jq -n --arg items "$body" '{body: ("More Codex findings arrived after merge:\n\n" + $items + "\n")}' \
      >"${TMPDIR:-/tmp}/late-codex-findings.$$.json"
    gh api -X POST "repos/$REPO/issues/$num/comments" --input "${TMPDIR:-/tmp}/late-codex-findings.$$.json" --jq .html_url \
      || { rm -f "${TMPDIR:-/tmp}/late-codex-findings.$$.json"; echo "late-codex-findings: cannot comment on #$num" >&2; exit 3; }
    rm -f "${TMPDIR:-/tmp}/late-codex-findings.$$.json"
  fi
}

if [ "$SWEEP" = 1 ]; then
  candidates=$(read_array "repos/$REPO/issues?state=closed&since=$SINCE&per_page=100" \
    | jq -r '.[] | select(.pull_request != null and .pull_request.merged_at != null) | .number')
  # One PR's read or write failure must not hide the others' findings, and
  # the next run would hit the same PR first. Each PR runs in its own
  # invocation (wrapping the function in `|| ...` would disable `set -e`
  # inside it), and any failure makes the sweep exit 3 after the loop.
  sweep_rc=0
  dry=()
  [ "$DRY_RUN" = 0 ] || dry=(--dry-run)
  for pr in $candidates; do
    LATE_CODEX_BOT_LOGIN="$BOT" "$0" --repo "$REPO" --pr "$pr" ${dry[@]+"${dry[@]}"} \
      || { echo "late-codex-findings: sweep failed on $REPO#$pr; continuing" >&2; sweep_rc=3; }
  done
  echo "late-codex-findings: sweep since $SINCE checked $(printf '%s\n' "$candidates" | grep -c . || true) merged PR(s)"
  exit "$sweep_rc"
else
  process_pr "$PR"
fi
