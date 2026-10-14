#!/usr/bin/env bash
# tests/test_required_check_publisher_due.sh
#
# Behavioural suite for the publish step's due-only targeting (#1130). It
# extracts the LIVE "Resolve targets, evaluate gates, publish" step from
# .github/workflows/required-check-publisher.yml and runs it with:
#   * a fake `gh` that answers each endpoint from a JSON fixture and applies
#     the step's own --jq expression with the real `jq`, so the step's
#     filters (including the job-run exclusion and the open-PR row format)
#     are exercised, not re-implemented here;
#   * stub gate scripts that record which PR each gate evaluated.
#
# Cases:
#   1. PR-event pass: the event head and every PR without positive proof of a
#      current green slot are evaluated; only the current-green PR is skipped.
#      Proof failures covered: pending hold, red verdict, activity after the
#      verdict, verdict older than DUE_MAX_AGE_SECONDS, failed read, missing
#      context, and a green job-run that must not count for the API slot.
#   2. Schedule-parent pass (main tip): full coverage.
#   3. Schedule-parent pass whose head is an open PR: still full coverage.
#   4. repository_dispatch: full coverage.
#   5. PR-event pass whose head no longer matches an open PR: full coverage.
#   6. Newest-by-id wins: an older green under a newer hold is not proof.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"

command -v ruby >/dev/null 2>&1 || { echo "ERROR: Ruby is required" >&2; exit 1; }
ruby -e 'require "yaml"' >/dev/null 2>&1 || { echo "ERROR: Ruby YAML support is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rcp-due.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ruby - "$WORKFLOW" "$TMP/publish.sh" "$TMP/env.json" <<'RUBY'
require "yaml"
require "json"
workflow = YAML.load_file(ARGV[0])
steps = workflow.fetch("jobs").fetch("publish").fetch("steps")
matches = steps.select { |step| step["name"] == "Resolve targets, evaluate gates, publish" }
abort("could not extract the publisher publish step") unless matches.length == 1 && matches[0]["run"].is_a?(String)
File.write(ARGV[1], matches[0]["run"])
File.write(ARGV[2], JSON.dump(workflow.fetch("env", {})))
RUBY

mkdir -p "$TMP/bin" "$TMP/work/scripts"
for g in merge-clearance-gate.sh codex-p1-gate.sh coderabbit-severity-gate.sh; do
  cat >"$TMP/work/scripts/$g" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(basename "$0")" "$1" >>"$GATE_LOG"
[ "$(basename "$0")" = merge-clearance-gate.sh ] && echo "Merge clearance: PASS"
exit 0
SH
  chmod +x "$TMP/work/scripts/$g"
done

cat >"$TMP/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, re, subprocess, sys
args = sys.argv[1:]
assert args and args[0] == "api", args
args = args[1:]
method, fields, jq, endpoint = "GET", {}, None, None
i = 0
while i < len(args):
    a = args[i]
    if a in ("--paginate", "--slurp"):
        i += 1; continue
    if a == "-X":
        method = args[i + 1]; i += 2; continue
    if a in ("-f", "-F"):
        k, _, v = args[i + 1].partition("="); fields[k] = v; i += 2; continue
    if a == "--jq":
        jq = args[i + 1]; i += 2; continue
    endpoint = a; i += 1
fx = json.load(open(os.environ["FIXTURE"]))
with open(os.environ["GH_LOG"], "a") as log:
    log.write(f"{method} {endpoint} {json.dumps(fields, sort_keys=True)}\n")
repo = os.environ["REPO"]
path = endpoint[len("repos/" + repo):] if endpoint.startswith("repos/" + repo) else endpoint
body = None
if method == "GET" and path == f"/actions/runs/{os.environ['GITHUB_RUN_ID']}":
    body = {"run_started_at": fx["pass_start"]}
elif method == "GET" and path == "/pulls":
    body = fx["prs"]
elif method == "GET" and re.fullmatch(r"/pulls/\d+", path):
    n = int(path.rsplit("/", 1)[1])
    body = {"head": {"sha": next(p["head"]["sha"] for p in fx["prs"] if p["number"] == n)}}
elif method == "GET" and re.fullmatch(r"/commits/[^/]+/check-runs", path):
    sha = path.split("/")[2]
    if fields.get("filter") == "all":
        if sha in fx.get("fail_reads", []):
            sys.stderr.write("HTTP 502\n"); sys.exit(1)
        body = {"check_runs": fx["runs"].get(sha, [])}
    else:
        body = {"check_runs": []}  # freshness / superseded-head probes: nothing newer
elif method == "POST" and path == "/check-runs":
    body = {"id": 900000000 + sum(1 for _ in open(os.environ["GH_LOG"]))}
else:
    sys.stderr.write(f"unexpected gh call: {method} {endpoint}\n"); sys.exit(3)
out = json.dumps(body)
if jq:
    r = subprocess.run(["jq", "-r", jq], input=out, capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stderr); sys.exit(r.returncode)
    out = r.stdout.rstrip("\n")
if out:
    print(out)
PY
chmod +x "$TMP/bin/gh"

PASS=0
FAIL=0
N=0

# Fixture builder: PASS_START 03:00:00Z, DUE_MAX_AGE_SECONDS 900, so the
# cutoff is 02:45:00Z. GOOD() is a current green API-slot run set.
python3 - "$TMP/fixture.json" <<'PY'
import json, sys
CTX = ["Merge clearance gate", "Codex P1 unresolved threads", "CodeRabbit unresolved blocking findings"]
def runs(status="completed", concl="success", done="2026-10-14T02:58:00Z", base=1000, skip=(), job_green=False):
    out = []
    for k, c in enumerate(CTX):
        if c in skip:
            continue
        out.append({"name": c, "id": base + k, "status": status, "conclusion": concl if status == "completed" else None,
                    "completed_at": done if status == "completed" else None, "details_url": f"https://github.com/o/r/runs/{base + k}"})
        if job_green:
            out.append({"name": c, "id": base + 500 + k, "status": "completed", "conclusion": "success",
                        "completed_at": done, "details_url": "https://github.com/o/r/actions/runs/1/job/2"})
    return out
def pr(n, upd="2026-10-14T02:50:00Z"):
    return {"number": n, "head": {"sha": f"h{n}"}, "updated_at": upd}
newest_hold = runs(base=1000) + [{"name": c, "id": 2000 + k, "status": "in_progress", "conclusion": None,
                                  "completed_at": None, "details_url": f"https://github.com/o/r/runs/{2000 + k}"} for k, c in enumerate(CTX)]
fx = {
  "pass_start": "2026-10-14T03:00:00Z",
  "prs": [pr(1), pr(2), pr(3), pr(4), pr(5, upd="2026-10-14T02:59:00Z"), pr(6, upd="2026-10-14T02:30:00Z"), pr(7), pr(8), pr(9), pr(10)],
  "runs": {
    "h1": runs(concl="failure"),                      # event head: evaluated regardless
    "h2": runs(),                                     # current green: SKIPPED
    "h3": runs(status="in_progress"),                 # pending hold: due
    "h4": runs(concl="failure"),                      # red verdict: due
    "h5": runs(),                                     # activity after verdict: due
    "h6": runs(done="2026-10-14T02:40:00Z"),          # quiet since, but older than 900s: due
    "h8": runs(skip=("Codex P1 unresolved threads",)),# missing context: due
    "h9": runs(concl="failure", job_green=True),      # job-run green must not count: due
    "h10": newest_hold,                               # newer hold beats older green: due
  },
  "fail_reads": ["h7"],                               # unreadable: due
}
json.dump(fx, open(sys.argv[1], "w"))
PY

run_pass() {  # run_pass <label> <event_name> <run_head> <parent_event> <dispatch_pr>
  : >"$TMP/gates.log"; : >"$TMP/gh.log"
  local rc=0
  (
    cd "$TMP/work"
    export PATH="$TMP/bin:$PATH" FIXTURE="$TMP/fixture.json" GH_LOG="$TMP/gh.log" GATE_LOG="$TMP/gates.log"
    export REPO="acme/widget" GITHUB_RUN_ID=4242 GH_TOKEN=x
    export EVENT_NAME="$2" RUN_HEAD="$3" PARENT_EVENT="$4" DISPATCH_PR="$5" DUE_MAX_AGE_SECONDS=900
    export MCG_CONTEXT="Merge clearance gate" CODEX_P1_CONTEXT="Codex P1 unresolved threads"
    export CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings"
    bash "$TMP/publish.sh"
  ) >"$TMP/out.log" 2>&1 || rc=$?
  EVALUATED=$(awk -F'\t' '$1=="merge-clearance-gate.sh"{print $2}' "$TMP/gates.log" | sort -n | tr '\n' ' ' | sed 's/ $//')
  RC=$rc
}

expect_eval() {  # expect_eval <name> <expected PR list>
  N=$((N + 1))
  if [ "$EVALUATED" = "$2" ] && [ "$RC" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS [$N] $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL [$N] $1: evaluated '$EVALUATED' (want '$2'), rc=$RC" >&2
    sed 's/^/      /' "$TMP/out.log" | tail -25 >&2
  fi
}

echo "required-check publisher due-only targeting tests"

run_pass event workflow_run h1 pull_request_review ""
expect_eval "PR-event pass skips only the PR with proof of a current green slot" "1 3 4 5 6 7 8 9 10"
N=$((N + 1))
if grep -q "Due-only event pass: evaluated 9 open PR(s), skipped 1 current one(s)." "$TMP/out.log" \
   && grep -q "PR #2 @ h2: green" "$TMP/out.log"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] the pass reports what it skipped"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] skip report missing" >&2; fi
N=$((N + 1))
if [ "$(awk -F'\t' '$1=="merge-clearance-gate.sh"' "$TMP/gates.log" | head -1 | cut -f2)" = 1 ]; then
  PASS=$((PASS + 1)); echo "  PASS [$N] the event head is still evaluated first"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] event head not first" >&2; fi

run_pass schedule-main workflow_run maintip schedule ""
expect_eval "schedule-parent pass on main's tip keeps full coverage" "1 2 3 4 5 6 7 8 9 10"
N=$((N + 1))
if ! grep -q 'filter' "$TMP/gh.log" || ! grep -q '"filter": "all"' "$TMP/gh.log"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] a full pass spends no due-proof reads"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] full pass issued due-proof reads" >&2; fi

run_pass schedule-pr workflow_run h1 schedule ""
expect_eval "schedule-parent pass whose head is an open PR keeps full coverage" "1 2 3 4 5 6 7 8 9 10"

run_pass dispatch repository_dispatch "" "" 2
expect_eval "repository_dispatch keeps full coverage" "1 2 3 4 5 6 7 8 9 10"

run_pass moved workflow_run hgone pull_request ""
expect_eval "PR-event pass on a head no open PR carries keeps full coverage" "1 2 3 4 5 6 7 8 9 10"

echo "required-check publisher due-only targeting tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
