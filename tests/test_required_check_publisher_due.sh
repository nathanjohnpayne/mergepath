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
#
# #2220 (installation-budget exhaustion) cases, same extracted step:
#   7. The due threshold is the workflow's own DUE_MAX_AGE_SECONDS (read from
#      the step env, not restated here): a 20-minute-old quiet green is
#      current at 1800 s, a 35-minute-old one is due.
#   8. Budget guard: below the threshold an event pass evaluates only the
#      event head (whose holds it still closes), spends no due() read on the
#      rest, and writes nothing on any skipped PR; a budget that covers the
#      head but not every due PR does the same after the due reads; a
#      schedule-parent pass and a dispatch evaluate nothing new (the dispatch
#      opens no holds); an unreadable /rate_limit evaluates as before.
#   9. Stop at the first installation rate-limit failure: no later PR is
#      evaluated or written; on the event head itself the remaining contexts
#      are closed with the rate-limit red without being evaluated.
#  10. Back-off round trip: the red case 9 actually POSTed makes that PR not
#      due before the reset its title records and due after it; an ordinary
#      infra red stays due; a red whose title records no reset backs off for
#      at most one hour.
#  11. One evaluation per PR per scheduled tick: the gate sweep defers to the
#      publisher (its find step is skipped wherever the publisher exists), and
#      the schedule-parent pass runs each gate exactly once per PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"

command -v ruby >/dev/null 2>&1 || { echo "ERROR: Ruby is required" >&2; exit 1; }
ruby -e 'require "yaml"' >/dev/null 2>&1 || { echo "ERROR: Ruby YAML support is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rcp-due.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ruby - "$WORKFLOW" "$TMP/publish.sh" "$TMP/env.json" "$TMP/step-env.sh" <<'RUBY'
require "yaml"
require "json"
workflow = YAML.load_file(ARGV[0])
steps = workflow.fetch("jobs").fetch("publish").fetch("steps")
matches = steps.select { |step| step["name"] == "Resolve targets, evaluate gates, publish" }
abort("could not extract the publisher publish step") unless matches.length == 1 && matches[0]["run"].is_a?(String)
File.write(ARGV[1], matches[0]["run"])
File.write(ARGV[2], JSON.dump(workflow.fetch("env", {})))
# The step's own tuning knobs (#2220), so the cases below run against the
# shipped values rather than copies of them.
env = matches[0].fetch("env", {})
knobs = %w[DUE_MAX_AGE_SECONDS BUDGET_PER_PR_REQUESTS BUDGET_RESERVE_REQUESTS]
missing = knobs.reject { |k| env[k].to_s =~ /\A[0-9]+\z/ }
abort("publish step env lacks integer #{missing.join(', ')}") unless missing.empty?
File.write(ARGV[3], knobs.map { |k| "export #{k}=#{env[k]}\n" }.join)
RUBY
# shellcheck disable=SC1091
. "$TMP/step-env.sh"

mkdir -p "$TMP/bin" "$TMP/work/scripts"
for g in merge-clearance-gate.sh codex-p1-gate.sh coderabbit-severity-gate.sh; do
  cat >"$TMP/work/scripts/$g" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(basename "$0")" "$1" >>"$GATE_LOG"
# RL_FAIL_PR: this PR's first gate fails the way an exhausted installation
# budget makes gh fail (#2220): the API message on stderr, an infra rc.
if [ "${RL_FAIL_PR:-}" = "$1" ]; then
  echo "gh: API rate limit exceeded for installation ID 4242. (HTTP 403)" >&2
  exit 2
fi
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
if method == "GET" and endpoint == "rate_limit":
    # GET /rate_limit (#2220). RL_REMAINING=fail makes it unreadable.
    if os.environ.get("RL_REMAINING", "") == "fail":
        sys.stderr.write("HTTP 502\n"); sys.exit(1)
    body = {"resources": {"core": {"limit": 1000, "remaining": int(os.environ.get("RL_REMAINING", "1000")),
                                   "reset": fx["rl_reset"]}}}
elif method == "GET" and path == f"/actions/runs/{os.environ['GITHUB_RUN_ID']}":
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

# Fixture builder: PASS_START 03:00:00Z and the step's own
# DUE_MAX_AGE_SECONDS (1800 since #2220), so the cutoff is 02:30:00Z. GOOD()
# is a current green API-slot run set. The installation window resets at
# 03:20:00Z (epoch 1791948000).
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
  "rl_reset": 1791948000,
  "prs": [pr(1), pr(2), pr(3), pr(4), pr(5, upd="2026-10-14T02:59:00Z"), pr(6, upd="2026-10-14T02:20:00Z"), pr(7), pr(8), pr(9), pr(10),
          pr(11, upd="2026-10-14T02:10:00Z")],
  "runs": {
    "h1": runs(concl="failure"),                      # event head: evaluated regardless
    "h2": runs(),                                     # current green: SKIPPED
    "h3": runs(status="in_progress"),                 # pending hold: due
    "h4": runs(concl="failure"),                      # red verdict: due
    "h5": runs(),                                     # activity after verdict: due
    "h6": runs(done="2026-10-14T02:40:00Z"),          # quiet, 20 min old: current at 1800s (was due at 900s)
    "h11": runs(done="2026-10-14T02:25:00Z"),         # quiet since, but older than 1800s: due
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
    export EVENT_NAME="$2" RUN_HEAD="$3" PARENT_EVENT="$4" DISPATCH_PR="$5"
    [ -z "${CASE_FIXTURE:-}" ] || FIXTURE="$CASE_FIXTURE"
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
expect_eval "PR-event pass skips only the PRs with proof of a current green slot" "1 3 4 5 7 8 9 10 11"
N=$((N + 1))
if grep -q "Due-only event pass: evaluated 9 open PR(s), skipped 2 current one(s)." "$TMP/out.log" \
   && grep -q "PR #2 @ h2: green" "$TMP/out.log" && grep -q "PR #6 @ h6: green" "$TMP/out.log"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] the pass reports what it skipped"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] skip report missing" >&2; fi
N=$((N + 1))
if [ "$(awk -F'\t' '$1=="merge-clearance-gate.sh"' "$TMP/gates.log" | head -1 | cut -f2)" = 1 ]; then
  PASS=$((PASS + 1)); echo "  PASS [$N] the event head is still evaluated first"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] event head not first" >&2; fi

run_pass schedule-main workflow_run maintip schedule ""
expect_eval "schedule-parent pass on main's tip keeps full coverage" "1 2 3 4 5 6 7 8 9 10 11"
N=$((N + 1))
if ! grep -q 'filter' "$TMP/gh.log" || ! grep -q '"filter": "all"' "$TMP/gh.log"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] a full pass spends no due-proof reads"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] full pass issued due-proof reads" >&2; fi

run_pass schedule-pr workflow_run h1 schedule ""
expect_eval "schedule-parent pass whose head is an open PR keeps full coverage" "1 2 3 4 5 6 7 8 9 10 11"

run_pass dispatch repository_dispatch "" "" 2
expect_eval "repository_dispatch keeps full coverage" "1 2 3 4 5 6 7 8 9 10 11"

run_pass moved workflow_run hgone pull_request ""
expect_eval "PR-event pass on a head no open PR carries keeps full coverage" "1 2 3 4 5 6 7 8 9 10 11"

# ── #2220: helpers over the recorded gh traffic ────────────────────────
# posts <head> [status]: number of check-run POSTs on <head> (optionally with
# that status). Reads the fake's own request log, so it counts what the step
# actually sent.
posts() {
  python3 - "$TMP/gh.log" "$1" "${2:-}" <<'PY2'
import json, sys
n = 0
for line in open(sys.argv[1]):
    method, endpoint, fields = line.rstrip("\n").split(" ", 2)
    f = json.loads(fields)
    if method == "POST" and endpoint.endswith("/check-runs") and f.get("head_sha") == sys.argv[2] \
            and (not sys.argv[3] or f.get("status") == sys.argv[3]):
        n += 1
print(n)
PY2
}
# writes_outside <head...>: heads other than these that received ANY POST.
writes_outside() {
  python3 - "$TMP/gh.log" "$@" <<'PY2'
import json, sys
allowed = set(sys.argv[2:])
hit = set()
for line in open(sys.argv[1]):
    method, endpoint, fields = line.rstrip("\n").split(" ", 2)
    f = json.loads(fields)
    if method == "POST" and f.get("head_sha") not in allowed:
        hit.add(f.get("head_sha"))
print(" ".join(sorted(hit)))
PY2
}
check() {  # check <name> <command...>: one assertion
  local name="$1"; shift
  N=$((N + 1))
  if "$@"; then PASS=$((PASS + 1)); echo "  PASS [$N] $name"
  else FAIL=$((FAIL + 1)); echo "  FAIL [$N] $name" >&2; sed 's/^/      /' "$TMP/out.log" | tail -25 >&2; fi
}
gates_ran() {  # gates_ran: "<script>:<pr>" for every gate invocation, sorted
  awk -F'\t' '{ print $1 ":" $2 }' "$TMP/gates.log" | sort | tr '\n' ' ' | sed 's/ $//'
}
no_due_reads() { ! grep -q '"filter": "all"' "$TMP/gh.log"; }

echo "#2220 installation-budget cases"

# ── 7. due threshold is the shipped DUE_MAX_AGE_SECONDS ────────────────
check "the step ships DUE_MAX_AGE_SECONDS=1800, the */30 sweep interval" \
  [ "$DUE_MAX_AGE_SECONDS" = 1800 ]

# ── 8. budget guard ────────────────────────────────────────────────────
# 150 remaining: below one extra PR (40) on top of the head (40) plus the
# 100 reserve, so no due() read is spent and only the event head runs.
RL_REMAINING=150 run_pass budget-head workflow_run h1 pull_request ""
unset RL_REMAINING
expect_eval "short budget: an event pass evaluates only the event head" "1"
check "short budget: no due() read is spent on the skipped PRs" no_due_reads
check "short budget: the event head's holds are opened and all three closed" \
  [ "$(posts h1 in_progress)" = 3 -a "$(posts h1 completed)" = 3 ]
check "short budget: no skipped PR receives any write (keeps its previous verdict)" \
  [ -z "$(writes_outside h1)" ]
check "short budget: the pass says what it skipped" \
  grep -q 'Budget guard (#2220): 150 installation request(s) remain until 2026-10-14T03:20:00Z.*Skipped: #2 #3 #4 #5 #6 #7 #8 #9 #10 #11' "$TMP/out.log"

# 300 remaining: covers the head plus one (180), so the due reads run, but
# not the nine due PRs (460): still only the event head.
RL_REMAINING=300 run_pass budget-after-due workflow_run h1 pull_request ""
unset RL_REMAINING
expect_eval "budget short of every due PR: still only the event head" "1"
check "budget short of every due PR: the due reads ran, and nothing outside h1 was written" \
  eval '! no_due_reads && [ -z "$(writes_outside h1)" ]'

RL_REMAINING=150 run_pass budget-schedule workflow_run maintip schedule ""
unset RL_REMAINING
expect_eval "short budget: a schedule-parent pass evaluates nothing new" ""
check "short budget: the schedule-parent pass writes nothing and says so" \
  eval '[ -z "$(writes_outside)" ] && grep -q "evaluating nothing new" "$TMP/out.log"'

RL_REMAINING=150 run_pass budget-dispatch repository_dispatch "" "" 2
unset RL_REMAINING
expect_eval "short budget: a dispatch evaluates nothing new" ""
check "short budget: the dispatch opens no hold it could not close" \
  [ -z "$(writes_outside)" ]

RL_REMAINING=fail run_pass budget-unreadable workflow_run h1 pull_request ""
unset RL_REMAINING
expect_eval "unreadable /rate_limit: the event pass evaluates as before" "1 3 4 5 7 8 9 10 11"
check "unreadable /rate_limit: the pass warns" \
  grep -q 'Could not read the installation budget' "$TMP/out.log"

# ── 9. stop at the first installation rate-limit failure ───────────────
RL_FAIL_PR=3 run_pass stop-later workflow_run h1 pull_request ""
check "rate-limit stop: no gate runs after the failing one" \
  [ "$(gates_ran)" = "coderabbit-severity-gate.sh:1 codex-p1-gate.sh:1 merge-clearance-gate.sh:1 merge-clearance-gate.sh:3" ]
check "rate-limit stop: only the failing context is written on its PR; later PRs untouched" \
  eval '[ "$(posts h3)" = 1 ] && [ -z "$(writes_outside h1 h3)" ]'
check "rate-limit stop: the pass exits red and names what it did not evaluate" \
  eval '[ "$RC" -ne 0 ] && grep -q "Not evaluated: #4 #5 #7 #8 #9 #10 #11" "$TMP/out.log"'
cp "$TMP/gh.log" "$TMP/gh-stop.log"

RL_FAIL_PR=1 run_pass stop-head workflow_run h1 pull_request ""
check "rate-limit stop on the event head: nothing else is evaluated" \
  [ "$(gates_ran)" = "merge-clearance-gate.sh:1" ]
check "rate-limit stop on the event head: all three holds are closed, none orphaned" \
  eval '[ "$(posts h1 in_progress)" = 3 ] && [ "$(posts h1 completed)" = 3 ] && [ -z "$(writes_outside h1)" ]'
unset RL_FAIL_PR

# ── 10. back-off round trip, from the red case 9 actually posted ────────
python3 - "$TMP/fixture.json" "$TMP/gh-stop.log" "$TMP" <<'PY2'
import copy, json, sys
fx = json.load(open(sys.argv[1]))
red = None
for line in open(sys.argv[2]):
    method, endpoint, fields = line.rstrip("\n").split(" ", 2)
    f = json.loads(fields)
    if method == "POST" and f.get("head_sha") == "h3" and f.get("status") == "completed":
        red = f
assert red and red["conclusion"] == "failure", red
title = red["output[title]"]
assert "re-evaluated after 2026-10-14T03:20:00Z" in title, title
# The red completes at 02:58; h3's other two contexts are current greens
# posted a minute before the pass, so the red alone decides whether h3 is due.
def with_h3(t, start, green_done):
    out = copy.deepcopy(fx)
    out["pass_start"] = start
    for r in out["runs"]["h3"]:
        r.update(status="completed", conclusion="success", completed_at=green_done)
        if r["name"] == red["name"]:
            r.update(conclusion="failure", id=r["id"] + 5000, completed_at="2026-10-14T02:58:00Z",
                     output={"title": t})
    return out
cases = {
    "before": with_h3(title, "2026-10-14T03:10:00Z", "2026-10-14T03:09:00Z"),
    "after": with_h3(title, "2026-10-14T03:21:00Z", "2026-10-14T03:20:30Z"),
    "ordinary": with_h3(red["name"] + " — infra/config error (rc=2)", "2026-10-14T03:10:00Z", "2026-10-14T03:09:00Z"),
    "cap-before": with_h3(title.split(";")[0], "2026-10-14T03:50:00Z", "2026-10-14T03:49:00Z"),
    "cap-after": with_h3(title.split(";")[0], "2026-10-14T04:00:00Z", "2026-10-14T03:59:00Z"),
}
for k, v in cases.items():
    json.dump(v, open(f"{sys.argv[3]}/fx-{k}.json", "w"))
PY2
h3_evaluated() { awk -F'\t' '$1=="merge-clearance-gate.sh" && $2==3' "$TMP/gates.log" | grep -q .; }

CASE_FIXTURE="$TMP/fx-before.json" run_pass backoff-before workflow_run h1 pull_request ""
check "back-off: a rate-limit red is not due before the reset its title records" \
  eval '! h3_evaluated && grep -q "PR #3 @ h3: newest verdict is an installation rate-limit red; backed off until 2026-10-14T03:20:00Z" "$TMP/out.log"'
CASE_FIXTURE="$TMP/fx-after.json" run_pass backoff-after workflow_run h1 pull_request ""
check "back-off: the first pass after the reset evaluates it" h3_evaluated
CASE_FIXTURE="$TMP/fx-ordinary.json" run_pass backoff-ordinary workflow_run h1 pull_request ""
check "back-off: an ordinary infra red stays due" h3_evaluated
CASE_FIXTURE="$TMP/fx-cap-before.json" run_pass backoff-cap-before workflow_run h1 pull_request ""
check "back-off: a red recording no reset backs off for its first hour" eval '! h3_evaluated'
CASE_FIXTURE="$TMP/fx-cap-after.json" run_pass backoff-cap-after workflow_run h1 pull_request ""
check "back-off: and is due once that hour has passed" h3_evaluated
unset CASE_FIXTURE

# ── 11. one evaluation per PR per scheduled tick ───────────────────────
run_pass tick workflow_run maintip schedule ""
check "scheduled tick: the publisher runs each gate exactly once per open PR" \
  eval '[ "$(wc -l <"$TMP/gates.log" | tr -d " ")" = 33 ] && [ -z "$(sort "$TMP/gates.log" | uniq -d)" ]'
GATE_WF="$ROOT/.github/workflows/merge-clearance-gate.yml"
check "scheduled tick: the gate sweep defers to the publisher wherever it exists" \
  ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    steps = wf.dig("jobs", "scheduled-sweep", "steps") || []
    find = steps.select { |s| s["name"] == "Find open PRs" }
    evaluate = steps.select { |s| s["name"] == "Re-evaluate gate per PR and post check_run" }
    cond = find.length == 1 ? find[0]["if"].to_s : ""
    path = cond[/\AhashFiles\(\x27([^\x27]+)\x27\) == \x27\x27\z/, 1]
    ok = path == ".github/workflows/required-check-publisher.yml" &&
         File.exist?(File.join(ARGV[1], path)) &&
         evaluate.length == 1 && evaluate[0]["if"] == "steps.find.outputs.prs != \x27\x27"
    exit(ok ? 0 : 1)' "$GATE_WF" "$ROOT"

echo "required-check publisher due-only targeting tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
