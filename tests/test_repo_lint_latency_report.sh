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

jq -n '{runs:[range(0;20) as $i | {
  id: ($i + 1), head_sha:("sha" + ($i|tostring)), event:"pull_request",
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
  conclusion:"success",
  duration_seconds:(500 + 10*$i),
  jobs:[
    {name:"lint-fast", conclusion:"success", duration_seconds:(80 + $i), steps:[]},
    {name:"deep-safety (consumer)", conclusion:"success", duration_seconds:(450 + 10*$i), steps:[]},
    {name:"lint", conclusion:"success", duration_seconds:5}
  ]
}]' "$TMP/healthy.json" > "$TMP/healthy-with-deep.json"
mv "$TMP/healthy-with-deep.json" "$TMP/healthy.json"

if bash "$SUBJECT" --input "$TMP/healthy.json" --out-dir "$TMP/healthy" --min-sample 20; then
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
bash "$SUBJECT" --input "$TMP/duplicate.json" --out-dir "$TMP/duplicate" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.status == "alert" and (.duplicate_heads | length) == 1 and .duplicate_heads[0].head_sha == "sha0"' "$TMP/duplicate/summary.json" >/dev/null; then
  pass "same-SHA duplicate workflow executions produce an actionable alert"
else
  fail "same-SHA duplicates must alert (rc=$rc)"
fi

jq '.runs += [(.runs[0] | .id=96 | .event="push" | .conclusion="failure" | .duration_seconds=null)]' "$TMP/healthy.json" > "$TMP/failed-duplicate.json"
set +e
bash "$SUBJECT" --input "$TMP/failed-duplicate.json" --out-dir "$TMP/failed-duplicate" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '(.duplicate_heads | length) == 1 and .duplicate_heads[0].head_sha == "sha0"' "$TMP/failed-duplicate/summary.json" >/dev/null; then
  pass "failed duplicate executions still trigger the waste alert"
else
  fail "duplicate detection must include failed and cancelled runs (rc=$rc)"
fi

jq '.runs += [(.runs[0] | .id=98 | .event="schedule"), (.runs[0] | .id=97 | .event="schedule")] | .runs |= map(select(.id != 1))' "$TMP/healthy.json" > "$TMP/scheduled-repeat.json"
if bash "$SUBJECT" --input "$TMP/scheduled-repeat.json" --out-dir "$TMP/scheduled-repeat" --min-sample 19 >/dev/null \
   && jq -e '(.duplicate_heads | length) == 0' "$TMP/scheduled-repeat/summary.json" >/dev/null; then
  pass "repeated scheduled backstops on an unchanged SHA are not duplicate-PR alerts"
else
  fail "scheduled backstops must not trigger duplicate-PR alerts"
fi

jq '.runs |= map(.duration_seconds += 300)' "$TMP/healthy.json" > "$TMP/slow.json"
set +e
bash "$SUBJECT" --input "$TMP/slow.json" --out-dir "$TMP/slow" --min-sample 20 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.status == "alert" and (.alerts | index("ordinary_pr_p50_regression")) != null and (.alerts | index("deep_pr_p95_regression")) != null' "$TMP/slow/summary.json" >/dev/null; then
  pass "ordinary and deep threshold regressions fail the audit"
else
  fail "latency regression must alert (rc=$rc)"
fi

jq '.runs = .runs[:2]' "$TMP/healthy.json" > "$TMP/small.json"
if bash "$SUBJECT" --input "$TMP/small.json" --out-dir "$TMP/small" --min-sample 20 \
   && jq -e '.status == "insufficient-sample" and .ordinary_pr.n == 2' "$TMP/small/summary.json" >/dev/null; then
  pass "small samples report insufficiency without a false regression alert"
else
  fail "small samples must be visible but non-alerting"
fi

echo "test_repo_lint_latency_report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
