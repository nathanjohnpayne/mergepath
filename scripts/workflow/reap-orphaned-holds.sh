#!/usr/bin/env bash
# Close orphaned holds on the three Mergepath Checks-API contexts (#2907).
#
# Usage: reap-orphaned-holds.sh <owner/repo>
#
# A hold is an `in_progress` Checks-API run on one of the three contexts:
# the publisher's phase-1 "(re-evaluation in progress)" entries, an owned
# generation, or a native gate lease. Its writer closes it, or, for phase-1
# holds, a newer generation supersedes it. When the writer dies first (an
# Actions incident, a dropped delivery), nothing else ever completes it, and
# the head's check suite stays in progress for good. On
# friends-and-family-billing#583 (2026-10-30) six such holds outlived every
# later green verdict, the armed auto-merge never fired, and the owner had
# to admin-merge.
#
# A hold is reaped only when all of these hold:
#   * it is still incomplete, on an open PR head, written by github-actions
#     through the Checks API (not a native Actions job run);
#   * it started at least REAP_MIN_AGE_SECONDS ago (default one hour);
#   * a NEWER run of the same name (higher id) on the same head has
#     completed, so a later evaluation already owns the verdict.
# It is closed `cancelled`, never green: whatever ordering GitHub applies,
# the reaped run cannot clear a context. The newer completed run keeps
# deciding it. The opening's summary is kept as the prefix of the new
# summary, so a still-living writer can still bind and close its own id.
#
# Called by the publisher's scheduled full-coverage pass, which holds the
# github-actions token with checks: write. Exit 1 when any read or write
# failed; holds it could not close stay as they were (fail closed).

set -euo pipefail

repo="${1:-}"
if ! [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "usage: reap-orphaned-holds.sh <owner/repo>" >&2
  exit 2
fi
min_age="${REAP_MIN_AGE_SECONDS:-3600}"
max_closes="${REAP_MAX_CLOSES:-60}"
now="${REAP_NOW_EPOCH:-$(date -u +%s)}"
for value in "$min_age" "$max_closes" "$now"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "::error::reaper bound is not a non-negative integer: '$value'" >&2; exit 2; }
done
contexts='["Merge clearance gate","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings"]'

if ! heads=$(gh api --paginate -X GET "repos/$repo/pulls" -f state=open -f per_page=100 \
    --jq '.[] | "\(.number)\t\(.head.sha)"'); then
  echo "::error::Could not list open PRs on $repo; no hold reaped."
  exit 1
fi

failed=0
closed=0
while IFS=$'\t' read -r pr head; do
  [ -n "$head" ] || continue
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
  if ! runs=$(gh api --paginate --slurp -X GET "repos/$repo/commits/$head/check-runs" \
      -f filter=all -f per_page=100); then
    echo "::warning::Could not read check runs for PR #$pr at $head; its holds stay as they are."
    failed=1
    continue
  fi
  if ! orphans=$(jq -c --argjson ctx "$contexts" --argjson now "$now" --argjson age "$min_age" '
      [ .[].check_runs[]
        | select(.name as $n | $ctx | index($n) != null)
        | select(((.details_url // "") | test("/actions/runs/")) | not)
        | select((.app.slug // "") == "github-actions") ] as $runs
      | $runs[]
      | select(.status != "completed") as $hold
      | select((($hold.started_at // "") | try fromdateiso8601 catch null) as $t
               | $t != null and $now - $t >= $age)
      | ([ $runs[] | select(.name == $hold.name and .status == "completed" and .id > $hold.id) ]
         | max_by(.id)) as $newer
      | select($newer != null)
      | {id: $hold.id, name: $hold.name, newer: $newer.id, summary: ($hold.output.summary // "")}
    ' <<<"$runs"); then
    echo "::warning::Could not parse check runs for PR #$pr at $head; its holds stay as they are."
    failed=1
    continue
  fi
  while IFS= read -r orphan; do
    [ -n "$orphan" ] || continue
    if [ "$closed" -ge "$max_closes" ]; then
      echo "::notice::Reaped $closed hold(s), the per-pass bound; the rest wait for the next sweep."
      break 2
    fi
    id=$(jq -r .id <<<"$orphan")
    name=$(jq -r .name <<<"$orphan")
    newer=$(jq -r .newer <<<"$orphan")
    # Re-read just before the write: a writer that closed its own hold since
    # the listing keeps its verdict.
    if ! status=$(gh api "repos/$repo/check-runs/$id" --jq .status); then
      echo "::warning::Could not re-read hold $id on PR #$pr; left as it is."
      failed=1
      continue
    fi
    [ "$status" != completed ] || continue
    summary="$(jq -r .summary <<<"$orphan")

Closed by the scheduled reaper (#2907): this hold outlived its writer, and the newer completed run $newer on the same head decides this context."
    title="$name (orphaned hold closed; see run $newer)"
    if gh api -X PATCH "repos/$repo/check-runs/$id" -f status=completed -f conclusion=cancelled -f "output[title]=$title" -f "output[summary]=${summary:0:60000}" >/dev/null; then # NO_BARE_GH_WRITE_EXEMPT: Actions-only cancellation of an orphaned Checks API hold under workflow GITHUB_TOKEN (checks:write), never interactive author/reviewer PATs.
      echo "Reaped orphaned hold $id ($name) on PR #$pr at $head; newer completed run $newer decides it."
      closed=$((closed + 1))
    else
      echo "::warning::Could not close orphaned hold $id on PR #$pr; it stays in progress."
      failed=1
    fi
  done <<<"$orphans"
done <<<"$heads"

echo "Reaper: closed $closed orphaned hold(s) on $repo."
exit "$failed"
