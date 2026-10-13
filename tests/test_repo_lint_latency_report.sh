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

# --- alert → tracking issue routing (#2165) ----------------------------------
# The verdict reaches ONE marker-keyed issue through
# scripts/repo-lint-latency-issue.sh. The workflow is asserted structurally;
# the router runs against a PATH-shimmed gh that records every call.

ROUTER="$ROOT/scripts/repo-lint-latency-issue.sh"
if [ ! -x "$ROUTER" ]; then
  fail "missing executable $ROUTER"
fi

if command -v yq >/dev/null 2>&1 \
   && yq -o=json '.' "$WORKFLOW" | jq -e '.permissions.issues == "write" and .permissions.actions == "read"
             and ([.jobs.report.steps[] | select(.name == "Route the audit verdict to the tracking issue")
                   | select((.if | contains("steps.latency.outputs.rc == '\''0'\''")) and (.if | contains("steps.latency.outputs.rc == '\''1'\''")))
                   | select((.run | contains("scripts/repo-lint-latency-issue.sh")) and (.run | contains("--labels \"area:ci-infra,audit\"")) and (.run | contains("--rc \"$AUDIT_RC\"")))
                   | select(.env.GH_TOKEN == "${{ secrets.GITHUB_TOKEN }}")] | length == 1)
             and (([.jobs.report.steps[] | .name] | index("Route the audit verdict to the tracking issue")) < ([.jobs.report.steps[] | .name] | index("Enforce latency and duplication alerts")))' >/dev/null; then
  pass "workflow routes rc 0/1 to the tracking-issue script with GITHUB_TOKEN issues:write before enforcing the alert"
else
  fail "workflow must carry the marker-keyed tracking-issue step (issues:write, both verdict rcs, before the enforce step)"
fi

SHIM="$TMP/router-shim"
mkdir -p "$SHIM/bin"
cat > "$SHIM/bin/gh" <<'SH'
#!/usr/bin/env bash
# Records every call; serves canned reads from $SHIM_STATE.
printf '%s\n' "$*" >> "$SHIM_STATE/calls.log"
case "$1 $2" in
  "issue list")
    [ ! -f "$SHIM_STATE/list-fail" ] || { echo "gh: HTTP 500" >&2; exit 1; }
    cat "$SHIM_STATE/issues.json" ;;
  "label list")
    cat "$SHIM_STATE/labels.txt" ;;
  "label create")
    [ ! -f "$SHIM_STATE/label-create-fail" ] || { echo "gh: forbidden" >&2; exit 1; }
    echo "$3" >> "$SHIM_STATE/labels.txt" ;;
  "issue create")
    while [ "$#" -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$SHIM_STATE/created-body.md"; shift; done
    echo "https://github.com/octo/demo/issues/123" ;;
  "issue edit")
    while [ "$#" -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$SHIM_STATE/edited-body.md"; shift; done ;;
  "issue comment"|"issue close") ;;
  *) echo "gh shim: unhandled: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$SHIM/bin/gh"

# route <state-dir> <rc> [extra args]  — runs the router against a fresh state
route() {
  local state="$1" rc="$2"; shift 2
  : > "$state/calls.log"
  PATH="$SHIM/bin:$PATH" SHIM_STATE="$state" GH_TOKEN=test-token \
    bash "$ROUTER" --repo octo/demo --rc "$rc" --run-url "https://example.test/run/1" \
      --summary "$TMP/slow/summary.json" --summary-md "$TMP/slow/summary.md" "$@"
}
calls() { cat "$1/calls.log"; }
MARKER='<!-- mergepath-repo-lint-latency-audit -->'
ALERTS="$(jq -r '.alerts | join(",")' "$TMP/slow/summary.json")"

# 1. alert, no tracking issue, labels present → create with both labels, marker + alerts marker in the body
S1="$SHIM/s1"; mkdir -p "$S1"
printf '[{"number":5,"body":"unrelated"}]' > "$S1/issues.json"
printf 'audit\narea:ci-infra\nbug\n' > "$S1/labels.txt"
set +e; out=$(route "$S1" 1 2>&1); rc=$?; set -e
if [ "$rc" -eq 0 ] && grep -Fq 'issue create --repo octo/demo --title Repo-lint latency audit alert --label area:ci-infra --label audit --body-file ' "$S1/calls.log" \
   && grep -Fxq "$MARKER" "$S1/created-body.md" \
   && grep -Fxq "<!-- repo-lint-latency-alerts: ${ALERTS} -->" "$S1/created-body.md" \
   && [ "$ALERTS" = "ordinary_pr_p50_regression,ordinary_pr_p95_regression,deep_pr_p95_regression" ] \
   && grep -Fq '| ordinary PR |' "$S1/created-body.md" \
   && grep -Fq 'https://example.test/run/1' "$S1/created-body.md" \
   && ! grep -Fq 'label create' "$S1/calls.log" \
   && printf '%s\n' "$out" | grep -Fxq 'issue=123'; then
  pass "alert with no tracking issue opens one, labelled, marker-keyed, carrying the report"
else
  fail "alert create (rc=$rc): $out $(calls "$S1")"
fi

# 2. alert, existing marker issue with the same alert set → body refreshed, no comment, no create
S2="$SHIM/s2"; mkdir -p "$S2"
jq -n --arg m "$MARKER" --arg a "$ALERTS" '[{number: 90, body: ($m + "\n<!-- repo-lint-latency-alerts: " + $a + " -->\nold")},
                         {number: 77, body: ($m + "\n<!-- repo-lint-latency-alerts: " + $a + " -->\nold")},
                         {number: 5, body: "Repo-lint latency audit alert (hand-written, no marker)"}]' > "$S2/issues.json"
printf 'audit\narea:ci-infra\n' > "$S2/labels.txt"
set +e; out=$(route "$S2" 1 2>&1); rc=$?; set -e
if [ "$rc" -eq 0 ] && grep -Fq 'issue edit 77 --repo octo/demo --title Repo-lint latency audit alert --body-file' "$S2/calls.log" \
   && grep -Fxq "$MARKER" "$S2/edited-body.md" \
   && ! grep -Fq 'issue create' "$S2/calls.log" \
   && ! grep -Fq 'issue comment' "$S2/calls.log" \
   && ! grep -Fq 'issue edit 90' "$S2/calls.log" \
   && printf '%s\n' "$out" | grep -Fxq 'issue=77'; then
  pass "alert with an existing marker issue refreshes the lowest-numbered one in place and posts no comment when the alert set is unchanged"
else
  fail "alert refresh (rc=$rc): $out $(calls "$S2")"
fi

# 3. alert, existing issue with a different alert set → refreshed AND commented
S3="$SHIM/s3"; mkdir -p "$S3"
jq -n --arg m "$MARKER" '[{number: 77, body: ($m + "\n<!-- repo-lint-latency-alerts: deep_pr_p95_regression -->\nold")}]' > "$S3/issues.json"
printf 'audit\narea:ci-infra\n' > "$S3/labels.txt"
set +e; out=$(route "$S3" 1 2>&1); rc=$?; set -e
if [ "$rc" -eq 0 ] && grep -Fq 'issue edit 77 --repo octo/demo --title' "$S3/calls.log" \
   && grep -Fq 'issue comment 77 --repo octo/demo --body :warning: Alert set changed' "$S3/calls.log" \
   && grep -Fq '(was: deep_pr_p95_regression)' "$S3/calls.log"; then
  pass "a changed alert set is commented on the refreshed issue"
else
  fail "alert change comment (rc=$rc): $out $(calls "$S3")"
fi

# 4. recovery with an open tracking issue → closed with a recovery comment; nothing created
S4="$SHIM/s4"; mkdir -p "$S4"
jq -n --arg m "$MARKER" '[{number: 77, body: ($m + "\nold")}, {number: 5, body: "unrelated"}]' > "$S4/issues.json"
printf 'audit\narea:ci-infra\n' > "$S4/labels.txt"
set +e; out=$(route "$S4" 0 2>&1); rc=$?; set -e
if [ "$rc" -eq 0 ] && grep -Fq 'issue close 77 --repo octo/demo --comment :white_check_mark: Repo-lint latency audit recovered' "$S4/calls.log" \
   && ! grep -Fq 'issue close 5' "$S4/calls.log" \
   && ! grep -Fq 'issue create' "$S4/calls.log"; then
  pass "a clean verdict comments on and closes the open tracking issue"
else
  fail "recovery close (rc=$rc): $out $(calls "$S4")"
fi

# 5. recovery with nothing open, and a no-verdict rc → no writes at all
S5="$SHIM/s5"; mkdir -p "$S5"
printf '[]' > "$S5/issues.json"; printf 'audit\n' > "$S5/labels.txt"
set +e
route "$S5" 0 >/dev/null 2>&1; rc_clean=$?
writes_clean=$(grep -c -E 'issue (create|edit|comment|close)|label create' "$S5/calls.log" || true)
route "$S5" 3 >/dev/null 2>&1; rc_none=$?
reads_none=$(grep -c . "$S5/calls.log" || true)
set -e
if [ "$rc_clean" -eq 0 ] && [ "$writes_clean" -eq 0 ] && [ "$rc_none" -eq 0 ] && [ "$reads_none" -eq 0 ]; then
  pass "a clean verdict with no open issue and a no-verdict exit write nothing (and the latter reads nothing)"
else
  fail "no-op paths (clean=$rc_clean writes=$writes_clean none=$rc_none reads=$reads_none)"
fi

# 6. an unreadable dedupe read fails closed: no issue is created on top of one that may exist
S6="$SHIM/s6"; mkdir -p "$S6"
printf '[]' > "$S6/issues.json"; printf 'audit\narea:ci-infra\n' > "$S6/labels.txt"; : > "$S6/list-fail"
set +e; out=$(route "$S6" 1 2>&1); rc=$?; set -e
if [ "$rc" -eq 1 ] && ! grep -Fq 'issue create' "$S6/calls.log" && printf '%s' "$out" | grep -Fq '::error::Could not list open issues'; then
  pass "a failed dedupe read exits 1 without opening a duplicate"
else
  fail "list failure (rc=$rc): $out $(calls "$S6")"
fi

# 7. a missing label is created; one that cannot be created degrades the filter, not the issue, and fails the step
S7="$SHIM/s7"; mkdir -p "$S7"
printf '[]' > "$S7/issues.json"; printf 'bug\n' > "$S7/labels.txt"
set +e; out=$(route "$S7" 1 2>&1); rc=$?; set -e
S8="$SHIM/s8"; mkdir -p "$S8"
printf '[]' > "$S8/issues.json"; printf 'audit\n' > "$S8/labels.txt"; : > "$S8/label-create-fail"
set +e; out8=$(route "$S8" 1 2>&1); rc8=$?; set -e
if [ "$rc" -eq 0 ] && grep -Fq 'label create area:ci-infra --repo octo/demo' "$S7/calls.log" && grep -Fq 'label create audit --repo octo/demo' "$S7/calls.log" \
   && grep -Fq -- '--label area:ci-infra --label audit --body-file' "$S7/calls.log" \
   && [ "$rc8" -eq 1 ] && grep -Fq 'issue create --repo octo/demo --title Repo-lint latency audit alert --label audit --body-file' "$S8/calls.log" \
   && printf '%s' "$out8" | grep -Fq '::error::A tracking label could not be ensured'; then
  pass "missing labels are created; an unensurable label still files the issue and then fails the step"
else
  fail "label handling (rc=$rc rc8=$rc8): $(calls "$S7") --- $(calls "$S8") $out8"
fi

echo "test_repo_lint_latency_report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
