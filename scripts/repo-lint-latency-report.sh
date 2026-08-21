#!/usr/bin/env bash
# Build a rolling repo-lint latency and duplicate-execution report.

set -euo pipefail

INPUT=""
REPO="${GITHUB_REPOSITORY:-}"
OUT_DIR=".mergepath/repo-lint-latency"
LIMIT=100
MIN_SAMPLE=20
P50_MAX=300
P95_MAX=480
DEEP_P95_MAX=720

usage() {
  echo "usage: repo-lint-latency-report.sh [--input FILE] [--repo owner/repo] [--out-dir DIR] [--limit N] [--min-sample N] [--p50-max SECONDS] [--p95-max SECONDS] [--deep-p95-max SECONDS]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) [ "$#" -ge 2 ] || usage; INPUT="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --out-dir) [ "$#" -ge 2 ] || usage; OUT_DIR="$2"; shift 2 ;;
    --limit) [ "$#" -ge 2 ] || usage; LIMIT="$2"; shift 2 ;;
    --min-sample) [ "$#" -ge 2 ] || usage; MIN_SAMPLE="$2"; shift 2 ;;
    --p50-max) [ "$#" -ge 2 ] || usage; P50_MAX="$2"; shift 2 ;;
    --p95-max) [ "$#" -ge 2 ] || usage; P95_MAX="$2"; shift 2 ;;
    --deep-p95-max) [ "$#" -ge 2 ] || usage; DEEP_P95_MAX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

for value in "$LIMIT" "$MIN_SAMPLE" "$P50_MAX" "$P95_MAX" "$DEEP_P95_MAX"; do
  case "$value" in ''|*[!0-9]*) usage ;; esac
done
[ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 100 ] || usage
command -v jq >/dev/null 2>&1 || { echo "repo-lint latency: jq is required" >&2; exit 2; }
mkdir -p "$OUT_DIR"

DATA="$OUT_DIR/runs.json"

if [ -n "$INPUT" ]; then
  jq -e '.runs | type == "array"' "$INPUT" >/dev/null \
    || { echo "repo-lint latency: input must contain a runs array" >&2; exit 2; }
  jq --argjson limit "$LIMIT" '{runs:(.runs[:$limit])}' "$INPUT" > "$DATA"
else
  [ -n "$REPO" ] || { echo "repo-lint latency: --repo or GITHUB_REPOSITORY is required" >&2; exit 2; }
  command -v gh >/dev/null 2>&1 || { echo "repo-lint latency: gh is required for live collection" >&2; exit 2; }
  [ -n "${GH_TOKEN:-}" ] || { echo "repo-lint latency: GH_TOKEN is required for live collection" >&2; exit 2; }

  RETRY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-retry-helpers.sh"
  if [ -f "$RETRY_HELPER" ]; then
    # shellcheck source=scripts/lib/gh-retry-helpers.sh
    source "$RETRY_HELPER"
  else
    with_gh_retry() { "$@"; }
  fi

  RUN_LIST="$OUT_DIR/workflow-runs.json"
  # The report is intentionally bounded to one Actions page. Using
  # --paginate and slicing afterward still downloads the repository's entire
  # workflow history before jq can apply LIMIT — minutes of needless API work.
  if ! with_gh_retry gh api "repos/$REPO/actions/workflows/repo_lint.yml/runs?status=completed&per_page=$LIMIT" --jq '.workflow_runs[]' \
      | jq -s --argjson limit "$LIMIT" '.[0:$limit]' > "$RUN_LIST"; then
    echo "repo-lint latency: could not fetch workflow runs" >&2
    exit 3
  fi

  : > "$OUT_DIR/normalized-runs.jsonl"
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    run_id=$(jq -r '.id' <<<"$run")
    jobs_file="$OUT_DIR/jobs-$run_id.json"
    # Retain the complete job objects (including IDs, timestamps, URLs, and
    # raw step records) beside the normalized report so the artifact can
    # support a later audit without re-querying mutable Actions history.
    if ! with_gh_retry gh api --paginate "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" --jq '.jobs[]' \
        | jq -s '.' > "$jobs_file"; then
      echo "repo-lint latency: could not fetch jobs for run $run_id" >&2
      exit 3
    fi
    jobs=$(<"$jobs_file")
    jq -cn --argjson run "$run" --argjson jobs "$jobs" '
      def seconds($start; $end):
        if ($start == null or $end == null) then null
        else (($end | fromdateiso8601) - ($start | fromdateiso8601))
        end;
      {
        id:$run.id,
        run_attempt:($run.run_attempt // 1),
        head_sha:$run.head_sha,
        event:$run.event,
        conclusion:$run.conclusion,
        created_at:$run.created_at,
        duration_seconds:seconds(($run.run_started_at // $run.created_at); $run.updated_at),
        jobs:[$jobs[] | {
          name, conclusion,
          duration_seconds:seconds(.started_at; .completed_at),
          steps:[.steps[]? | {
            name, conclusion,
            duration_seconds:seconds(.started_at; .completed_at)
          }]
        }]
      }' >> "$OUT_DIR/normalized-runs.jsonl"
  done < <(jq -c '.[]' "$RUN_LIST")
  jq -s '{runs:.}' "$OUT_DIR/normalized-runs.jsonl" > "$DATA"
fi

jq -c \
  --argjson min_sample "$MIN_SAMPLE" \
  --argjson p50_max "$P50_MAX" \
  --argjson p95_max "$P95_MAX" \
  --argjson deep_p95_max "$DEEP_P95_MAX" '
  def percentile($p):
    sort as $values
    | if ($values|length) == 0 then null
      else $values[((((($values|length) * $p) | ceil) - 1) | if . < 0 then 0 else . end)]
      end;
  def distribution($values):
    ($values | map(select(type == "number")) | sort) as $v
    | {n:($v|length), p50_seconds:($v|percentile(0.50)), p95_seconds:($v|percentile(0.95)), max_seconds:($v|max // null)};
  (.runs | map(select(.conclusion == "success" and .duration_seconds != null))) as $completed
  | ($completed | map(select(
      .event == "pull_request"
      and ([.jobs[]? | select((.name | startswith("deep-safety")) and .conclusion != "skipped")] | length) == 0
    ))) as $ordinary
  | ($completed | map(select(
      .event == "pull_request"
      and ([.jobs[]? | select((.name | startswith("deep-safety")) and .conclusion != "skipped")] | length) > 0
    ))) as $deep
  | (distribution([$ordinary[].duration_seconds])) as $ordinary_dist
  | (distribution([$deep[].duration_seconds])) as $deep_dist
  | (.runs
      | map(select((.event == "pull_request" or .event == "push") and (.head_sha // "") != ""))
      | group_by(.head_sha)
      | map(select((map(.id) | unique | length) > 1 and (map(.event) | index("pull_request")) != null)
        | {head_sha:.[0].head_sha, run_ids:(map(.id)|unique), events:(map(.event)|unique)})
    ) as $duplicates
  | ([ $ordinary[]
       | .jobs[]?
       | select(.conclusion != "skipped" and .duration_seconds != null)
       | {name, duration_seconds}]
      | sort_by(.name)
      | group_by(.name)
      | map({name:.[0].name} + distribution(map(.duration_seconds)))
    ) as $jobs
  | ([ $ordinary[]
       | .jobs[]? as $job
       | $job.steps[]?
       | select(.conclusion != "skipped" and .duration_seconds != null)
       | {name:($job.name + " / " + .name), duration_seconds}]
      | sort_by(.name)
      | group_by(.name)
      | map({name:.[0].name} + distribution(map(.duration_seconds)))
    ) as $steps
  | ([if ($ordinary_dist.n >= $min_sample and $ordinary_dist.p50_seconds > $p50_max) then "ordinary_pr_p50_regression" else empty end,
      if ($ordinary_dist.n >= $min_sample and $ordinary_dist.p95_seconds > $p95_max) then "ordinary_pr_p95_regression" else empty end,
      if ($deep_dist.n >= $min_sample and $deep_dist.p95_seconds > $deep_p95_max) then "deep_pr_p95_regression" else empty end,
      if ($duplicates|length) > 0 then "same_sha_duplicate_execution" else empty end]) as $alerts
  | {
      schema:"repo-lint-latency/v1",
      status:(if ($alerts|length)>0 then "alert" elif ($ordinary_dist.n < $min_sample or $deep_dist.n < $min_sample) then "insufficient-sample" else "healthy" end),
      thresholds:{min_sample:$min_sample,p50_max_seconds:$p50_max,p95_max_seconds:$p95_max,deep_p95_max_seconds:$deep_p95_max},
      ordinary_pr:$ordinary_dist,
      deep_pr:$deep_dist,
      alerts:$alerts,
      duplicate_heads:$duplicates,
      timings:{jobs:$jobs,steps:$steps}
    }
' "$DATA" > "$OUT_DIR/summary.json"

jq -r '
  def duration:
    if . == null then "n/a"
    else ((. / 60) | floor | tostring) + "m " + ((. % 60) | floor | tostring) + "s"
    end;
  "# Repo-lint latency\n\n" +
  "Status: **" + .status + "**\n\n" +
  "| segment | n | p50 | p95 |\n|---|---:|---:|---:|\n" +
  "| ordinary PR | " + (.ordinary_pr.n|tostring) + " | " + (.ordinary_pr.p50_seconds|duration) + " | " + (.ordinary_pr.p95_seconds|duration) + " |\n" +
  "| deep/governance PR | " + (.deep_pr.n|tostring) + " | " + (.deep_pr.p50_seconds|duration) + " | " + (.deep_pr.p95_seconds|duration) + " |\n\n" +
  "Thresholds: ordinary p50 <= " + (.thresholds.p50_max_seconds|duration) + ", ordinary p95 <= " + (.thresholds.p95_max_seconds|duration) + ", deep p95 <= " + (.thresholds.deep_p95_max_seconds|duration) + ", minimum sample per segment " + (.thresholds.min_sample|tostring) + ".\n\n" +
  "Duplicate heads: " + (.duplicate_heads|length|tostring) + ".\n\n" +
  (if (.alerts|length)>0 then "Alerts: " + (.alerts|join(", ")) + ".\n" else "Alerts: none.\n" end)
' "$OUT_DIR/summary.json" > "$OUT_DIR/summary.md"

cat "$OUT_DIR/summary.md"
[ "$(jq -r '.status' "$OUT_DIR/summary.json")" != "alert" ]
