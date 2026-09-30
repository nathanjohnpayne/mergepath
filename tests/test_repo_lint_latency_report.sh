#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/repo-lint-latency-report.sh"
WORKFLOW="$ROOT/.github/workflows/repo-lint-latency.yml"
WRAPPER="$ROOT/scripts/ci/check_repo_lint_latency_report"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-latency.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

if [ ! -x "$SUBJECT" ]; then
  echo "FAIL: missing executable $SUBJECT" >&2
  exit 1
fi

if command -v yq >/dev/null 2>&1 \
   && yq -e '.on.schedule[0].cron == "47 8 * * *" and .on.workflow_dispatch == null and .permissions.actions == "read" and ([.jobs.report.steps[] | select(.name == "Collect rolling repo-lint timing") | select((.run | contains("repo-lint-latency-report.sh")) and (.run | contains("rc=$?")) and (.run | contains("rc=$rc")))] | any) and ([.jobs.report.steps[] | select(.name == "Collect rolling repo-lint timing") | (.run | contains("--deep-p95-max 720"))] | any) and ([.jobs.report.steps[] | select(.name == "Upload timing evidence") | .uses | contains("actions/upload-artifact@")] | any) and ([.jobs.report.steps[] | select(.name == "Enforce latency and duplication alerts") | .if == "steps.latency.outputs.rc == '\''1'\''"] | any) and ([.jobs.report.steps[] | select(.name == "Report latency collection failure") | .if | contains("steps.latency.outputs.rc != '\''1'\''")] | any)' "$WORKFLOW" >/dev/null \
   && grep -Fq 'tests/test_repo_lint_latency_report.sh' "$WRAPPER"; then
  pass "scheduled workflow publishes summaries/artifacts and the CI wrapper owns this contract"
else
  fail "latency workflow or CI wrapper is not wired to the report contract"
fi

if grep -Fq 'runs?status=completed&per_page=$LIMIT' "$SUBJECT" \
   && ! grep -Fq -- '--paginate "repos/$REPO/actions/workflows/repo_lint.yml/runs' "$SUBJECT" \
   && grep -Fq 'jobs-$run_id.json' "$SUBJECT" \
   && [ "$(grep -c 'with_gh_retry gh api' "$SUBJECT")" -eq 2 ]; then
  pass "live collection is completed-only, bounded, retried, and retains raw per-run job evidence"
else
  fail "live collection must select completed runs, bound history, retry Actions reads, and preserve raw job responses"
fi

# Every run carries created_at inside the default 14-day window ending at
# AS_OF; the report windows by created_at before anything else (#1062).
AS_OF="2026-09-28T00:00:00Z"
run_report() { bash "$SUBJECT" --as-of "$AS_OF" "$@"; }

jq -n '{runs:[range(0;20) as $i | {
  id: ($i + 1), head_sha:("sha" + ($i|tostring)), event:"pull_request",
  created_at:("2026-09-20T00:" + (if $i < 10 then "0" else "" end) + ($i|tostring) + ":00Z"),
  conclusion:"success",
  duration_seconds:(100 + 10*$i),
  jobs:[
    {name:"lint-fast", conclusion:"success", duration_seconds:(80 + 10*$i),
     steps:[{name:"check_doc_ownership", duration_seconds:(20 + $i)}]},
    {name:"deep-safety (consumer)", conclusion:"skipped", duration_seconds:0},
    {name:"lint", conclusion:"success", duration_seconds:5}
  ]
}]}' > "$TMP/healthy.json"

jq '.runs += [range(0;20) as $i | {
  id: ($i + 101), head_sha:("deep-sha" + ($i|tostring)), event:"pull_request",
  created_at:("2026-09-21T00:" + (if $i < 10 then "0" else "" end) + ($i|tostring) + ":00Z"),
  conclusion:"success",
  duration_seconds:(500 + 10*$i),
  jobs:[
    {name:"lint-fast", conclusion:"success", duration_seconds:(80 + $i), steps:[]},
    {name:"deep-safety (consumer)", conclusion:"success", duration_seconds:(450 + 10*$i), steps:[]},
    {name:"lint", conclusion:"success", duration_seconds:5}
  ]
}]' "$TMP/healthy.json" > "$TMP/healthy-with-deep.json"
mv "$TMP/healthy-with-deep.json" "$TMP/healthy.json"

if run_report --input "$TMP/healthy.json" --out-dir "$TMP/healthy" --min-sample 20; then
  if jq -e '.ordinary_pr.n == 20 and .ordinary_pr.p50_seconds == 190 and .ordinary_pr.p95_seconds == 280 and .deep_pr.n == 20 and .deep_pr.p95_seconds == 680 and .status == "healthy" and (.timings.jobs[] | select(.name == "lint-fast") | .n == 20)' "$TMP/healthy/summary.json" >/dev/null \
     && grep -Fq '| ordinary PR | 20 | 3m 10s | 4m 40s |' "$TMP/healthy/summary.md" \
     && grep -Fq '| deep/governance PR | 20 | 9m 50s | 11m 20s |' "$TMP/healthy/summary.md"; then
    pass "healthy sample reports ordinary and deep acceptance percentiles"
  else
    fail "healthy sample summary is incorrect"
  fi
else
  fail "healthy sample must not alert"
fi

jq '.runs += [(.runs[0] | .id=99)]' "$TMP/healthy.json" > "$TMP/duplicate.json"
set +e
run_report --input "$TMP/duplicate.json" --out-dir "$TMP/duplicate" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.status == "alert" and (.duplicate_heads | length) == 1 and .duplicate_heads[0].head_sha == "sha0"' "$TMP/duplicate/summary.json" >/dev/null; then
  pass "same-SHA duplicate workflow executions produce an actionable alert"
else
  fail "same-SHA duplicates must alert (rc=$rc)"
fi

jq '.runs += [(.runs[0] | .id=96 | .event="push" | .conclusion="failure" | .duration_seconds=null)]' "$TMP/healthy.json" > "$TMP/failed-duplicate.json"
set +e
run_report --input "$TMP/failed-duplicate.json" --out-dir "$TMP/failed-duplicate" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '(.duplicate_heads | length) == 1 and .duplicate_heads[0].head_sha == "sha0"' "$TMP/failed-duplicate/summary.json" >/dev/null; then
  pass "failed duplicate executions still trigger the waste alert"
else
  fail "duplicate detection must include failed and cancelled runs (rc=$rc)"
fi

jq '.runs += [(.runs[0] | .id=98 | .event="schedule"), (.runs[0] | .id=97 | .event="schedule")] | .runs |= map(select(.id != 1))' "$TMP/healthy.json" > "$TMP/scheduled-repeat.json"
if run_report --input "$TMP/scheduled-repeat.json" --out-dir "$TMP/scheduled-repeat" --min-sample 19 >/dev/null \
   && jq -e '(.duplicate_heads | length) == 0' "$TMP/scheduled-repeat/summary.json" >/dev/null; then
  pass "repeated scheduled backstops on an unchanged SHA are not duplicate-PR alerts"
else
  fail "scheduled backstops must not trigger duplicate-PR alerts"
fi

jq '.runs |= map(.duration_seconds += 300)' "$TMP/healthy.json" > "$TMP/slow.json"
set +e
run_report --input "$TMP/slow.json" --out-dir "$TMP/slow" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.status == "alert" and (.alerts | index("ordinary_pr_p50_regression")) != null and (.alerts | index("deep_pr_p95_regression")) != null' "$TMP/slow/summary.json" >/dev/null; then
  pass "ordinary and deep threshold regressions fail the audit"
else
  fail "latency regression must alert (rc=$rc)"
fi

jq '.runs = .runs[:2]' "$TMP/healthy.json" > "$TMP/small.json"
if run_report --input "$TMP/small.json" --out-dir "$TMP/small" --min-sample 20 \
   && jq -e '.status == "insufficient-sample" and .ordinary_pr.n == 2' "$TMP/small/summary.json" >/dev/null; then
  pass "small samples report insufficiency without a false regression alert"
else
  fail "small samples must be visible but non-alerting"
fi

# #1062: the duplicate alert and the latency sample are bounded by TIME. A
# same-SHA push+PR pair from before the window (e.g. pre-#1065 history on a
# low-traffic consumer, whose last 100 runs reach back months) must not alert.
jq '.runs += [(.runs[0] | .id=201 | .head_sha="stale-sha" | .created_at="2026-08-01T00:00:00Z"),
              (.runs[0] | .id=202 | .head_sha="stale-sha" | .event="push" | .created_at="2026-08-01T00:00:05Z")]' \
  "$TMP/healthy.json" > "$TMP/stale-duplicate.json"
if run_report --input "$TMP/stale-duplicate.json" --out-dir "$TMP/stale-duplicate" --min-sample 20 >/dev/null \
   && jq -e '.status == "healthy" and (.duplicate_heads | length) == 0 and .window.days == 14 and .window.since == "2026-09-14T00:00:00Z" and .window.runs == 40' "$TMP/stale-duplicate/summary.json" >/dev/null; then
  pass "same-SHA duplicates created before the window do not alert"
else
  fail "stale pre-window duplicates must be excluded from the duplicate alert"
fi

# The same pair INSIDE the window still alerts.
jq '.runs += [(.runs[0] | .id=201 | .head_sha="fresh-sha" | .created_at="2026-09-27T00:00:00Z"),
              (.runs[0] | .id=202 | .head_sha="fresh-sha" | .event="push" | .created_at="2026-09-27T00:00:05Z")]' \
  "$TMP/healthy.json" > "$TMP/fresh-duplicate.json"
set +e
run_report --input "$TMP/fresh-duplicate.json" --out-dir "$TMP/fresh-duplicate" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '(.duplicate_heads | map(.head_sha)) == ["fresh-sha"]' "$TMP/fresh-duplicate/summary.json" >/dev/null; then
  pass "same-SHA duplicates inside the window still alert"
else
  fail "in-window duplicates must alert (rc=$rc)"
fi

# --window-days narrows the sample; LIMIT applies newest-first by created_at
# regardless of input order.
jq '.runs |= sort_by(.created_at)' "$TMP/healthy.json" > "$TMP/reversed.json"
if run_report --input "$TMP/reversed.json" --out-dir "$TMP/limited" --limit 5 --min-sample 1 >/dev/null 2>&1 || true; then :; fi
if jq -e '.runs | map(.id) == [120,119,118,117,116]' "$TMP/limited/runs.json" >/dev/null; then
  pass "LIMIT keeps the newest runs by created_at, not by input order"
else
  fail "LIMIT must select newest-first by created_at (got $(jq -c '.runs | map(.id)' "$TMP/limited/runs.json"))"
fi
if run_report --input "$TMP/healthy.json" --out-dir "$TMP/narrow" --window-days 7 --min-sample 20 >/dev/null \
   && jq -e '.window.runs == 20 and .ordinary_pr.n == 0 and .deep_pr.n == 20' "$TMP/narrow/summary.json" >/dev/null; then
  pass "--window-days excludes runs created before the narrower window"
else
  fail "--window-days must bound the sample by created_at"
fi

# Zero-prefixed --window-days values are decimal, not octal: 08 is 8 days
# (octal would be an error) and 010 is 10 days (octal would be 8).
if run_report --input "$TMP/healthy.json" --out-dir "$TMP/w08" --window-days 08 --min-sample 20 >/dev/null 2>&1 \
   && jq -e '.window.days == 8 and .window.since == "2026-09-20T00:00:00Z"' "$TMP/w08/summary.json" >/dev/null \
   && run_report --input "$TMP/healthy.json" --out-dir "$TMP/w010" --window-days 010 --min-sample 20 >/dev/null 2>&1 \
   && jq -e '.window.days == 10 and .window.since == "2026-09-18T00:00:00Z"' "$TMP/w010/summary.json" >/dev/null; then
  pass "--window-days 08 and 010 are read as decimal"
else
  fail "zero-prefixed --window-days must be decimal"
fi

# --as-of bounds BOTH ends: runs created after the cutoff (a replayed export)
# must not fill LIMIT or alert.
jq '.runs += [range(0;30) as $i | (.runs[0] | .id=(300+$i) | .head_sha="future-sha" | .event=(if $i % 2 == 0 then "push" else "pull_request" end) | .created_at="2026-09-29T00:00:00Z")]' \
  "$TMP/healthy.json" > "$TMP/future.json"
if run_report --input "$TMP/future.json" --out-dir "$TMP/future" --min-sample 20 >/dev/null \
   && jq -e '.window.runs == 40 and (.duplicate_heads | length) == 0 and .status == "healthy"' "$TMP/future/summary.json" >/dev/null; then
  pass "runs created after --as-of are excluded from the window"
else
  fail "runs after the as-of cutoff must be excluded"
fi

# A run without a parseable created_at cannot be placed in the window.
jq '.runs[3] |= del(.created_at)' "$TMP/healthy.json" > "$TMP/no-created.json"
jq '.runs[3].created_at = "yesterday"' "$TMP/healthy.json" > "$TMP/bad-created.json"
set +e
run_report --input "$TMP/no-created.json" --out-dir "$TMP/no-created" >/dev/null 2>&1; rc_missing=$?
run_report --input "$TMP/bad-created.json" --out-dir "$TMP/bad-created" >/dev/null 2>&1; rc_bad=$?
bash "$SUBJECT" --input "$TMP/healthy.json" --out-dir "$TMP/bad-window" --window-days 0 >/dev/null 2>&1; rc_window=$?
bash "$SUBJECT" --input "$TMP/healthy.json" --out-dir "$TMP/bad-asof" --as-of 2026-09-28 >/dev/null 2>&1; rc_asof=$?
set -e
if [ "$rc_missing" -eq 2 ] && [ "$rc_bad" -eq 2 ] && [ "$rc_window" -eq 2 ] && [ "$rc_asof" -eq 2 ]; then
  pass "missing/unparseable created_at and invalid window arguments are usage errors"
else
  fail "created_at/window validation (missing=$rc_missing bad=$rc_bad window=$rc_window asof=$rc_asof)"
fi

if grep -Fq 'created=%3E%3D$WINDOW_START' "$SUBJECT" \
   && grep -Fq -- '--window-days 14' "$WORKFLOW"; then
  pass "live collection filters by created>= and the workflow pins the 14-day window"
else
  fail "live collection must request created>=WINDOW_START and the workflow must pass --window-days"
fi

echo "test_repo_lint_latency_report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
