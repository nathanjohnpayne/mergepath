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
#      head and some due PRs evaluates the head plus a batch of that size; a
#      schedule-parent pass or dispatch with no capacity evaluates nothing new
#      (the dispatch opens no holds), and with some capacity evaluates a
#      ROTATING batch whose start advances by one per tick, so it covers every
#      PR within n ticks even when the capacity changes between ticks (#2229);
#      an unreadable /rate_limit evaluates as before.
#   9. Stop at the first installation rate-limit failure: no later PR is
#      evaluated or written; on the event head itself the remaining contexts
#      are closed with the rate-limit red without being evaluated.
#  10. Back-off round trip: the red case 9 actually POSTed makes that PR not
#      due before the reset its title records and due after it; an ordinary
#      infra red stays due; a red whose title records no reset backs off for
#      at most one hour.
#  11. The schedule-parent pass runs each gate exactly once per open PR.
#  12. Codex rounds on #2225: the GraphQL bucket, page-counted proof reads, a
#      head too expensive to evaluate, a lint-only refresh that must not write,
#      and a token so empty that no write after the failure lands.
#  13. #2229: a proof read that fails after one page is charged two requests.
#  14. #2239/#2205 auto-clear nominations: a green clearance verdict on a PR
#      carrying needs-external-review is nominated once; a red, withheld or
#      moved-head verdict, an unlabeled PR and a pass that evaluated nothing
#      nominate nothing; on full-coverage passes only, an unlabeled green PR
#      whose newest auto-clear-blocking-labels run is a failure is nominated
#      (one read per such PR), and the nominate-auto-clear job sends exactly
#      one repository_dispatch per nominated PR carrying only its number.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"

command -v ruby >/dev/null 2>&1 || { echo "ERROR: Ruby is required" >&2; exit 1; }
ruby -e 'require "yaml"' >/dev/null 2>&1 || { echo "ERROR: Ruby YAML support is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rcp-due.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ruby - "$WORKFLOW" "$TMP/publish.sh" "$TMP/env.json" "$TMP/step-env.sh" "$TMP/nominate.sh" <<'RUBY'
require "yaml"
require "json"
workflow = YAML.load_file(ARGV[0])
# #2239: the nominate-auto-clear job's single run block, for case 14.
nominate = workflow.fetch("jobs").fetch("nominate-auto-clear").fetch("steps")
abort("could not extract the nominate-auto-clear step") unless nominate.length == 1 && nominate[0]["run"].is_a?(String)
File.write(ARGV[4], nominate[0]["run"])
steps = workflow.fetch("jobs").fetch("publish").fetch("steps")
matches = steps.select { |step| step["name"] == "Resolve targets, evaluate gates, publish" }
abort("could not extract the publisher publish step") unless matches.length == 1 && matches[0]["run"].is_a?(String)
File.write(ARGV[1], matches[0]["run"])
File.write(ARGV[2], JSON.dump(workflow.fetch("env", {})))
# The step's own tuning knobs (#2220), so the cases below run against the
# shipped values rather than copies of them.
env = matches[0].fetch("env", {})
knobs = %w[DUE_MAX_AGE_SECONDS BUDGET_PER_PR_REQUESTS BUDGET_RESERVE_REQUESTS
           BUDGET_PER_PR_GRAPHQL_POINTS BUDGET_GRAPHQL_RESERVE_POINTS]
missing = knobs.reject { |k| env[k].to_s =~ /\A[0-9]+\z/ }
abort("publish step env lacks integer #{missing.join(', ')}") unless missing.empty?
File.write(ARGV[3], knobs.map { |k| "export #{k}=#{env[k]}\n" }.join)
RUBY
# shellcheck disable=SC1091
. "$TMP/step-env.sh"

mkdir -p "$TMP/bin" "$TMP/work/scripts/workflow"
cp "$ROOT/scripts/workflow/required-check-generation.sh" "$ROOT/scripts/workflow/installation-budget.sh" "$TMP/work/scripts/workflow/"
printf '#!/bin/sh\necho bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$TMP/bin/git"
chmod +x "$TMP/bin/git"
for g in merge-clearance-gate.sh codex-p1-gate.sh coderabbit-severity-gate.sh; do
  cat >"$TMP/work/scripts/$g" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(basename "$0")" "$1" >>"$GATE_LOG"
# RL_FAIL_PR: this PR's first gate fails the way an exhausted installation
# budget makes gh fail (#2220): the API message on stderr, an infra rc.
# RL_EXHAUST_BUCKET=graphql words it the way the GraphQL bucket does. Either
# way the failure marks the budget exhausted for the fake gh (EXHAUST_FLAG).
if [ "${RL_FAIL_PR:-}" = "$1" ]; then
  : >"$EXHAUST_FLAG"
  if [ "${RL_EXHAUST_BUCKET:-core}" = graphql ]; then
    echo "gh: API rate limit already exceeded for installation ID 4242." >&2
  else
    echo "gh: API rate limit exceeded for installation ID 4242. (HTTP 403)" >&2
  fi
  exit 2
fi
if [ "$(basename "$0")" = merge-clearance-gate.sh ]; then
  # MCG_RED_PRS (#2239): these PRs get a red clearance verdict.
  case " ${MCG_RED_PRS:-} " in *" $1 "*) echo "Merge clearance: FAIL"; exit 1 ;; esac
  echo "Merge clearance: PASS"
fi
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
repo = os.environ["REPO"]
if not (os.path.exists(os.environ.get("EXHAUST_FLAG", "/nonexistent"))
        and os.environ.get("RL_EXHAUST_WRITES") == "1" and endpoint != "rate_limit"):
    with open(os.environ["GH_LOG"], "a") as log:
        log.write(f"{method} {endpoint} {json.dumps(fields, sort_keys=True)}\n")
path = endpoint[len("repos/" + repo):] if endpoint.startswith("repos/" + repo) else endpoint
body = None
# Once a stub gate has failed on the budget (EXHAUST_FLAG), the bucket named
# by RL_EXHAUST_BUCKET reads 0, and with RL_EXHAUST_WRITES=1 every other call
# fails the way an exhausted installation token does — the production path in
# which no write after the failure can land (Codex P1 on #2225).
exhausted = os.path.exists(os.environ.get("EXHAUST_FLAG", "/nonexistent"))
if method == "GET" and endpoint == "rate_limit":
    # GET /rate_limit (#2220). RL_REMAINING=fail makes it unreadable.
    if os.environ.get("RL_REMAINING", "") == "fail":
        sys.stderr.write("HTTP 502\n"); sys.exit(1)
    core = int(os.environ.get("RL_REMAINING", "1000"))
    gql = int(os.environ.get("RL_GQL_REMAINING", "1000"))
    if exhausted:
        if os.environ.get("RL_EXHAUST_BUCKET", "core") == "graphql":
            gql = 0
        else:
            core = 0
    body = {"resources": {"core": {"limit": 1000, "remaining": core, "reset": fx["rl_reset"]},
                          "graphql": {"limit": 1000, "remaining": gql, "reset": fx["rl_gql_reset"]}}}
elif exhausted and os.environ.get("RL_EXHAUST_WRITES") == "1":
    with open(os.environ["GH_LOG"] + ".rejected", "a") as rej:
        rej.write(f"{method} {endpoint} {json.dumps(fields, sort_keys=True)}\n")
    sys.stderr.write("gh: API rate limit exceeded for installation ID 4242. (HTTP 403)\n"); sys.exit(1)
elif method == "GET" and path == f"/actions/runs/{os.environ['GITHUB_RUN_ID']}":
    body = {"run_started_at": fx["pass_start"]}
elif method == "GET" and path == "/commits/HEAD":
    body = {"sha": "b" * 40}
elif method == "GET" and re.fullmatch(r"/check-runs/\d+", path):
    wanted = int(path.rsplit("/", 1)[1])
    for index, line in enumerate(open(os.environ["GH_LOG"]), 1):
        m, e, raw = line.rstrip("\n").split(" ", 2)
        f = json.loads(raw)
        if m == "POST" and e.endswith("/check-runs") and 900000000 + index == wanted:
            body = {"id": wanted, "name": f["name"], "head_sha": f["head_sha"], "status": "in_progress",
                    "output": {"summary": f["output[summary]"]}}
            break
    assert body is not None, wanted
elif method == "PATCH" and re.fullmatch(r"/check-runs/\d+", path):
    body = {"id": int(path.rsplit("/", 1)[1])}
elif method == "GET" and path == "/pulls":
    body = fx["prs"]
elif method == "GET" and re.fullmatch(r"/pulls/\d+", path):
    n = int(path.rsplit("/", 1)[1])
    # moved_heads (#2239): the live head differs from the enumerated one.
    sha = fx.get("moved_heads", {}).get(str(n)) or next(p["head"]["sha"] for p in fx["prs"] if p["number"] == n)
    body = {"head": {"sha": sha}}
elif method == "GET" and re.fullmatch(r"/commits/[^/]+/check-runs", path) \
        and fields.get("check_name") == "auto-clear-blocking-labels":
    # #2205: the nomination step's read of the newest auto-clear run.
    sha = path.split("/")[2]
    if sha in fx.get("autoclear_fail_reads", []):
        sys.stderr.write("HTTP 502\n"); sys.exit(1)
    body = {"check_runs": fx.get("autoclear_runs", {}).get(sha, [])}
elif method == "GET" and re.fullmatch(r"/commits/[^/]+/check-runs", path):
    sha = path.split("/")[2]
    if fields.get("filter") == "all":
        if sha in fx.get("fail_reads", []):
            sys.stderr.write("HTTP 502\n"); sys.exit(1)
        runs_for = fx["runs"].get(sha, [])
        if sha in fx.get("page_then_fail", []) and jq:
            # Page 1 arrives (gh prints its --jq output), page 2 fails (#2229).
            r = subprocess.run(["jq", "-r", jq], input=json.dumps({"check_runs": runs_for[:len(runs_for) // 2]}),
                               capture_output=True, text=True)
            sys.stdout.write(r.stdout); sys.stdout.flush()
            sys.stderr.write("HTTP 502 on page 2\n"); sys.exit(1)
        if sha in fx.get("two_pages", []) and jq:
            # Two HTTP pages: gh applies --jq to each page separately.
            outs = []
            for page in (runs_for[:len(runs_for) // 2], runs_for[len(runs_for) // 2:]):
                r = subprocess.run(["jq", "-r", jq], input=json.dumps({"check_runs": page}),
                                   capture_output=True, text=True)
                if r.returncode:
                    sys.stderr.write(r.stderr); sys.exit(r.returncode)
                outs.append(r.stdout.rstrip("\n"))
            print("\n".join(o for o in outs if o)); sys.exit(0)
        body = {"check_runs": runs_for}
    else:
        body = {"check_runs": []}  # freshness / superseded-head probes: nothing newer
elif method == "POST" and path == "/check-runs":
    body = {"id": 900000000 + sum(1 for _ in open(os.environ["GH_LOG"])),
            "head_sha": fields["head_sha"], "name": fields["name"], "status": fields["status"],
            "output": {"summary": fields["output[summary]"]}}
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
    return {"number": n, "head": {"sha": f"{n:040x}"}, "updated_at": upd}
newest_hold = runs(base=1000) + [{"name": c, "id": 2000 + k, "status": "in_progress", "conclusion": None,
                                  "completed_at": None, "details_url": f"https://github.com/o/r/runs/{2000 + k}"} for k, c in enumerate(CTX)]
fx = {
  "pass_start": "2026-10-14T03:00:00Z",
  "rl_reset": 1791948000,
  "rl_gql_reset": 1791949200,
  "prs": [pr(1), pr(2), pr(3), pr(4), pr(5, upd="2026-10-14T02:59:00Z"), pr(6, upd="2026-10-14T02:20:00Z"), pr(7), pr(8), pr(9), pr(10),
          pr(11, upd="2026-10-14T02:10:00Z")],
  "runs": {
    "0000000000000000000000000000000000000001": runs(concl="failure"),                      # event head: evaluated regardless
    "0000000000000000000000000000000000000002": runs(),                                     # current green: SKIPPED
    "0000000000000000000000000000000000000003": runs(status="in_progress"),                 # pending hold: due
    "0000000000000000000000000000000000000004": runs(concl="failure"),                      # red verdict: due
    "0000000000000000000000000000000000000005": runs(),                                     # activity after verdict: due
    "0000000000000000000000000000000000000006": runs(done="2026-10-14T02:40:00Z"),          # quiet, 20 min old: current at 1800s (was due at 900s)
    "000000000000000000000000000000000000000b": runs(done="2026-10-14T02:25:00Z"),         # quiet since, but older than 1800s: due
    "0000000000000000000000000000000000000008": runs(skip=("Codex P1 unresolved threads",)),# missing context: due
    "0000000000000000000000000000000000000009": runs(concl="failure", job_green=True),      # job-run green must not count: due
    "000000000000000000000000000000000000000a": newest_hold,                               # newer hold beats older green: due
  },
  "fail_reads": ["0000000000000000000000000000000000000007"],                               # unreadable: due
}
json.dump(fx, open(sys.argv[1], "w"))
PY

run_pass() {  # run_pass <label> <event_name> <run_head> <parent_event> <dispatch_pr>
  : >"$TMP/gates.log"; : >"$TMP/gh.log"; : >"$TMP/github-output"; rm -f "$TMP/exhausted" "$TMP/gh.log.rejected"
  local rc=0
  (
    cd "$TMP/work"
    export PATH="$TMP/bin:$PATH" FIXTURE="$TMP/fixture.json" GH_LOG="$TMP/gh.log" GATE_LOG="$TMP/gates.log"
    export REPO="acme/widget" GITHUB_RUN_ID=4242 GH_TOKEN=x EXHAUST_FLAG="$TMP/exhausted"
    export EVENT_NAME="$2" RUN_HEAD="$3" PARENT_EVENT="$4" DISPATCH_PR="$5"
    export GITHUB_OUTPUT="$TMP/github-output"
    export PARENT_NAME="${CASE_PARENT_NAME:-Merge Clearance Gate}"
    # Cases express their original request budgets in 40-request units. Scale
    # evaluation capacity with the shipped estimate; proof-page costs stay real.
    case "${RL_REMAINING:-}" in
      ''|*[!0-9]*) ;;
      *) RL_REMAINING=$((BUDGET_RESERVE_REQUESTS + ((RL_REMAINING - 100) / 40) * BUDGET_PER_PR_REQUESTS + (RL_REMAINING - 100) % 40)); export RL_REMAINING ;;
    esac
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

run_pass event workflow_run 0000000000000000000000000000000000000001 pull_request_review ""
expect_eval "PR-event pass skips only the PRs with proof of a current green slot" "1 3 4 5 7 8 9 10 11"
N=$((N + 1))
if grep -q "Due-only event pass: evaluated 9 open PR(s), skipped 2 current one(s)." "$TMP/out.log" \
   && grep -q "PR #2 @ 0000000000000000000000000000000000000002: green" "$TMP/out.log" && grep -q "PR #6 @ 0000000000000000000000000000000000000006: green" "$TMP/out.log"; then
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

run_pass schedule-pr workflow_run 0000000000000000000000000000000000000001 schedule ""
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
opened = {}
for index, line in enumerate(open(sys.argv[1]), 1):
    method, endpoint, fields = line.rstrip("\n").split(" ", 2)
    f = json.loads(fields)
    if method == "POST" and endpoint.endswith("/check-runs"):
        opened[900000000 + index] = f
    if method == "PATCH":
        f = dict(opened.get(int(endpoint.rsplit("/", 1)[1]), {}), **f)
    if method in ("POST", "PATCH") and f.get("head_sha") == sys.argv[2] \
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
RL_REMAINING=150 run_pass budget-head workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_REMAINING
expect_eval "short budget: an event pass evaluates only the event head" "1"
check "short budget: no due() read is spent on the skipped PRs" no_due_reads
check "short budget: the event head's holds are opened and all three closed" \
  [ "$(posts 0000000000000000000000000000000000000001 in_progress)" = 3 -a "$(posts 0000000000000000000000000000000000000001 completed)" = 3 ]
check "short budget: no skipped PR receives any write (keeps its previous verdict)" \
  [ -z "$(writes_outside 0000000000000000000000000000000000000001)" ]
check "short budget: the pass says what it skipped" \
  grep -q 'Budget guard (#2220): .* REST request(s) and 1000 GraphQL point(s) remain until 2026-10-14T03:20:00Z.*Skipped: #2 #3 #4 #5 #6 #7 #8 #9 #10 #11' "$TMP/out.log"

# 300 remaining: covers the head plus some, but not the nine due PRs.
RL_REMAINING=300 run_pass budget-after-due workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_REMAINING
evaluated_list() { awk -F'\t' '$1=="merge-clearance-gate.sh"{print $2}' "$TMP/gates.log"; }
check "budget short of every due PR: the head plus a batch the budget covers, all of them due" \
  eval '[ "$(evaluated_list | head -1)" = 1 ] && [ "$(evaluated_list | wc -l | tr -d " ")" = 4 ] && ! evaluated_list | grep -qx -e 2 -e 6'
check "budget short of every due PR: writes land only on evaluated heads" \
  eval '[ -z "$(writes_outside $(evaluated_list | while read -r n; do printf "%040x\n" "$n"; done))" ]'

# 130 remaining: below one evaluation plus the reserve, so no capacity.
RL_REMAINING=130 run_pass budget-schedule workflow_run maintip schedule ""
unset RL_REMAINING
expect_eval "no capacity: a schedule-parent pass evaluates nothing new" ""
check "no capacity: the schedule-parent pass writes nothing and says so" \
  eval '[ -z "$(writes_outside)" ] && grep -q "evaluating nothing new" "$TMP/out.log"'

RL_REMAINING=130 run_pass budget-dispatch repository_dispatch "" "" 2
unset RL_REMAINING
expect_eval "no capacity: a dispatch evaluates nothing new" ""
check "no capacity: the dispatch opens no hold it could not close" \
  [ -z "$(writes_outside)" ]

# 150: capacity for one. The dispatch spends it on the named PR.
RL_REMAINING=150 run_pass budget-dispatch-one repository_dispatch "" "" 2
unset RL_REMAINING
expect_eval "capacity for one: a dispatch evaluates exactly its named PR" "2"

# Rotating batches (Codex P1 on #2225): at a capacity of 3, a schedule-parent
# pass evaluates exactly three PRs, and each tick's batch starts one position
# after the previous tick's (#2229).
# tick_fixture <k> <out>: the base fixture with PASS_START k sweep intervals
# after 03:00Z; prints that tick's index modulo the 11 open PRs.
tick_fixture() {
  python3 - "$TMP/fixture.json" "$2" "$1" "$DUE_MAX_AGE_SECONDS" <<'PY2'
import json, sys, datetime as d
fx = json.load(open(sys.argv[1]))
step = int(sys.argv[4])
t = d.datetime(2026, 10, 14, 3, 0, tzinfo=d.timezone.utc) + d.timedelta(seconds=step * int(sys.argv[3]))
fx["pass_start"] = t.strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(fx, open(sys.argv[2], "w"))
print(int(t.timestamp()) // step % len(fx["prs"]))
PY2
}
: >"$TMP/rotation.log"
for k in 0 1 2 3; do
  tick_fixture "$k" "$TMP/fx-tick.json" >/dev/null
  RL_REMAINING=220 CASE_FIXTURE="$TMP/fx-tick.json" run_pass "rotate-$k" workflow_run maintip schedule ""
  awk -F'\t' '$1=="merge-clearance-gate.sh"{print $2}' "$TMP/gates.log" | tr '\n' ' ' >>"$TMP/rotation.log"
  echo >>"$TMP/rotation.log"
done
check "rotating batch: each tick evaluates exactly the three PRs the budget covers" \
  awk 'NF != 3 { bad = 1 } END { exit bad + (NR != 4) }' "$TMP/rotation.log"
check "rotating batch: each tick's batch starts one position after the last" \
  awk 'NR > 1 && ($1 != p2 || $2 != p3) { bad = 1 } { p2 = $2; p3 = $3 } END { exit bad }' "$TMP/rotation.log"

# Varying capacity (#2229): one PR per tick, except two at the tick whose
# index modulo 11 is 5. Scaling the start by the batch size put that tick's
# batch at positions 10 and 0, so position 5 was never evaluated; a start
# that advances by one per tick covers all eleven within eleven ticks.
: >"$TMP/rotation-vary.log"
for k in 0 1 2 3 4 5 6 7 8 9 10; do
  pos=$(tick_fixture "$k" "$TMP/fx-tick.json")
  rem=150
  [ "$pos" != 5 ] || rem=190
  RL_REMAINING=$rem CASE_FIXTURE="$TMP/fx-tick.json" run_pass "rotate-vary-$k" workflow_run maintip schedule ""
  awk -F'\t' '$1=="merge-clearance-gate.sh"{print $2}' "$TMP/gates.log" | tr '\n' ' ' >>"$TMP/rotation-vary.log"
  echo >>"$TMP/rotation-vary.log"
done
check "rotating batch, varying capacity: each tick evaluates what the budget covers" \
  [ "$(tr ' ' '\n' <"$TMP/rotation-vary.log" | grep -c .)" = 12 ]
check "rotating batch, varying capacity: eleven ticks cover all eleven open PRs" \
  [ "$(tr ' ' '\n' <"$TMP/rotation-vary.log" | grep . | sort -un | wc -l | tr -d ' ')" = 11 ]
unset CASE_FIXTURE

RL_REMAINING=fail run_pass budget-unreadable workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_REMAINING
expect_eval "unreadable /rate_limit: the event pass evaluates as before" "1 3 4 5 7 8 9 10 11"
check "unreadable /rate_limit: the pass warns" \
  grep -q 'Could not read the installation budget' "$TMP/out.log"

# ── 9. stop at the first installation rate-limit failure ───────────────
RL_FAIL_PR=3 run_pass stop-later workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "rate-limit stop: no gate runs after the failing one" \
  [ "$(gates_ran)" = "coderabbit-severity-gate.sh:1 codex-p1-gate.sh:1 merge-clearance-gate.sh:1 merge-clearance-gate.sh:3" ]
check "rate-limit stop: only the failing context is written on its PR; later PRs untouched" \
  eval '[ "$(posts 0000000000000000000000000000000000000003 completed)" = 1 ] && [ -z "$(writes_outside 0000000000000000000000000000000000000001 0000000000000000000000000000000000000003)" ]'
check "rate-limit stop: the pass exits red and names what it did not evaluate" \
  eval '[ "$RC" -ne 0 ] && grep -q "Not evaluated: #4 #5 #7 #8 #9 #10 #11" "$TMP/out.log"'
cp "$TMP/gh.log" "$TMP/gh-stop.log"

RL_FAIL_PR=1 run_pass stop-head workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "rate-limit stop on the event head: nothing else is evaluated" \
  [ "$(gates_ran)" = "merge-clearance-gate.sh:1" ]
check "rate-limit stop on the event head: all three holds are closed, none orphaned" \
  eval '[ "$(posts 0000000000000000000000000000000000000001 in_progress)" = 3 ] && [ "$(posts 0000000000000000000000000000000000000001 completed)" = 3 ] && [ -z "$(writes_outside 0000000000000000000000000000000000000001)" ]'
unset RL_FAIL_PR

# ── 10. back-off round trip, from the red case 9 actually posted ────────
python3 - "$TMP/fixture.json" "$TMP/gh-stop.log" "$TMP" <<'PY2'
import copy, json, sys
fx = json.load(open(sys.argv[1]))
red = None
opened = {}
for index, line in enumerate(open(sys.argv[2]), 1):
    method, endpoint, fields = line.rstrip("\n").split(" ", 2)
    f = json.loads(fields)
    if method == "POST": opened[900000000 + index] = f
    if method == "PATCH": f = dict(opened.get(int(endpoint.rsplit("/", 1)[1]), {}), **f)
    if method == "PATCH" and f.get("head_sha") == "0000000000000000000000000000000000000003" and f.get("status") == "completed":
        red = f
assert red and red["conclusion"] == "failure", red
title = red["output[title]"]
assert "re-evaluated after 2026-10-14T03:20:00Z" in title, title
# The red completes at 02:58; 0000000000000000000000000000000000000003's other two contexts are current greens
# posted a minute before the pass, so the red alone decides whether 0000000000000000000000000000000000000003 is due.
def with_h3(t, start, green_done):
    out = copy.deepcopy(fx)
    out["pass_start"] = start
    for r in out["runs"]["0000000000000000000000000000000000000003"]:
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

CASE_FIXTURE="$TMP/fx-before.json" run_pass backoff-before workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "back-off: a rate-limit red is not due before the reset its title records" \
  eval '! h3_evaluated && grep -q "PR #3 @ 0000000000000000000000000000000000000003: newest verdict is an installation rate-limit red; backed off until 2026-10-14T03:20:00Z" "$TMP/out.log"'
CASE_FIXTURE="$TMP/fx-after.json" run_pass backoff-after workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "back-off: the first pass after the reset evaluates it" h3_evaluated
CASE_FIXTURE="$TMP/fx-ordinary.json" run_pass backoff-ordinary workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "back-off: an ordinary infra red stays due" h3_evaluated
CASE_FIXTURE="$TMP/fx-cap-before.json" run_pass backoff-cap-before workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "back-off: a red recording no reset backs off for its first hour" eval '! h3_evaluated'
CASE_FIXTURE="$TMP/fx-cap-after.json" run_pass backoff-cap-after workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "back-off: and is due once that hour has passed" h3_evaluated
unset CASE_FIXTURE

# ── 11. one evaluation per PR per scheduled tick ───────────────────────
run_pass tick workflow_run maintip schedule ""
check "scheduled tick: the publisher runs each gate exactly once per open PR" \
  eval '[ "$(wc -l <"$TMP/gates.log" | tr -d " ")" = 33 ] && [ -z "$(sort "$TMP/gates.log" | uniq -d)" ]'
# ── Codex round 1 on #2225 ─────────────────────────────────────────────
# The GraphQL bucket is budgeted too: a healthy REST core with an empty
# GraphQL bucket still evaluates only the event head.
RL_GQL_REMAINING=60 run_pass gql-short workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_GQL_REMAINING
expect_eval "short GraphQL budget: an event pass evaluates only the event head" "1"
# Selection reads are charged: at 185 the head plus one PR (180) is covered
# for exactly six proof reads, after which the rest are skipped unread.
RL_REMAINING=185 run_pass due-reads-charged workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_REMAINING
check "due-proof reads are charged against the budget snapshot" \
  [ "$(grep -c '"filter": "all"' "$TMP/gh.log")" = 6 ]
# Below one evaluation the head is not evaluated at all: its holds are closed
# with the budget red straight away, with no new holds and no gate run.
RL_REMAINING=120 run_pass prestop workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_REMAINING
check "budget short of one evaluation: no gate runs at all" [ ! -s "$TMP/gates.log" ]
check "budget short of one evaluation: the head is closed with three budget reds, no new holds" \
  eval '[ "$(posts 0000000000000000000000000000000000000001 in_progress)" = 3 ] && [ "$(posts 0000000000000000000000000000000000000001 completed)" = 3 ] && [ -z "$(writes_outside 0000000000000000000000000000000000000001)" ] && grep -q "installation API budget exhausted (rc=2); re-evaluated after 2026-10-14T03:20:00Z" "$TMP/gh.log"'
RL_GQL_REMAINING=20 run_pass prestop-gql workflow_run 0000000000000000000000000000000000000001 pull_request ""
unset RL_GQL_REMAINING
check "budget short on GraphQL only: the reds carry the GraphQL reset" \
  grep -q "re-evaluated after 2026-10-14T03:40:00Z" "$TMP/gh.log"
# A GraphQL exhaustion mid-pass: the GraphQL wording also stops the pass, and
# the red carries the bucket that ran out.
RL_FAIL_PR=3 RL_EXHAUST_BUCKET=graphql run_pass stop-gql workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "GraphQL rate-limit wording stops the pass" \
  [ "$(gates_ran)" = "coderabbit-severity-gate.sh:1 codex-p1-gate.sh:1 merge-clearance-gate.sh:1 merge-clearance-gate.sh:3" ]
check "GraphQL exhaustion: the red carries the GraphQL reset" \
  eval '[ "$(posts 0000000000000000000000000000000000000003 completed)" = 1 ] && grep -q "re-evaluated after 2026-10-14T03:40:00Z" "$TMP/gh.log"'
unset RL_EXHAUST_BUCKET
# The production path once the token is empty: every write after the failure
# fails as well. Nothing is written green, the event head's holds stay
# PENDING (fail closed), and the pass ends red rather than hanging.
# A lint-parent refresh opened no holds, so a budget short of one evaluation
# must leave the head untouched rather than close it red (Codex P1 on #2225).
RL_REMAINING=120 CASE_PARENT_NAME=repo-lint run_pass lint-prestop workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "budget short of one evaluation on a repo-lint refresh: no gate runs and nothing is written" \
  eval '[ ! -s "$TMP/gates.log" ] && [ -z "$(writes_outside)" ]'
# A proof read is charged per PAGE (Codex P2 on #2225): 0000000000000000000000000000000000000003's runs span two
# pages, so at 185 the reads stop one PR earlier than the six above.
python3 - "$TMP/fixture.json" "$TMP/fx-pages.json" <<'PY2'
import json, sys
fx = json.load(open(sys.argv[1])); fx["two_pages"] = ["0000000000000000000000000000000000000003"]
json.dump(fx, open(sys.argv[2], "w"))
PY2
RL_REMAINING=185 CASE_FIXTURE="$TMP/fx-pages.json" run_pass due-pages workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "a two-page proof read is charged two requests" \
  [ "$(grep -c '"filter": "all"' "$TMP/gh.log")" = 5 ]
# ── 13. #2229: a read that fails after one page ────────────────────────
# 0000000000000000000000000000000000000003's read prints page 1 and then fails on page 2: that is one page fetched
# plus the failed request, so it is charged two and, as with the two-page
# read above, the reads stop one PR earlier than the six at one per read.
python3 - "$TMP/fixture.json" "$TMP/fx-page-fail.json" <<'PY2'
import json, sys
fx = json.load(open(sys.argv[1])); fx["page_then_fail"] = ["0000000000000000000000000000000000000003"]
json.dump(fx, open(sys.argv[2], "w"))
PY2
RL_REMAINING=185 CASE_FIXTURE="$TMP/fx-page-fail.json" run_pass due-page-fail workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "a proof read that fails after one page is charged two requests" \
  [ "$(grep -c '"filter": "all"' "$TMP/gh.log")" = 5 ]
check "a proof read that fails after one page is not reported as current" \
  eval '! grep -q "PR #3 @ 0000000000000000000000000000000000000003:" "$TMP/out.log"'
RL_FAIL_PR=1 RL_EXHAUST_WRITES=1 run_pass stop-no-writes workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "exhausted token after the failure: no write lands and the holds stay pending" \
  eval '[ "$(posts 0000000000000000000000000000000000000001 in_progress)" = 3 ] && [ "$(posts 0000000000000000000000000000000000000001 completed)" = 0 ] && [ -z "$(writes_outside 0000000000000000000000000000000000000001)" ] && [ "$RC" -ne 0 ] && ! grep -q "\"conclusion\": \"success\"" "$TMP/gh.log" "$TMP/gh.log.rejected"'
unset RL_FAIL_PR RL_EXHAUST_WRITES

# ── 14. auto-clear nominations (#2239, #2205) ─────────────────────────
echo "#2239/#2205 auto-clear nomination cases"
# nominated: the space-separated autoclear_prs the step wrote for its job.
nominated() { sed -n 's/^autoclear_prs=//p' "$TMP/github-output"; }
# ac_reads: requests the nomination step spent on auto-clear check-run reads.
ac_reads() { grep -c '"check_name": "auto-clear-blocking-labels"' "$TMP/gh.log" || true; }
# Fixture: PRs 1, 3 and 4 carry needs-external-review (4 gets a red verdict
# below); 0000000000000000000000000000000000000002's newest auto-clear run is a stale failure listed FIRST (array
# order must not decide), 0000000000000000000000000000000000000005's newest is a success over an older failure, and
# 0000000000000000000000000000000000000006 has none.
python3 - "$TMP/fixture.json" "$TMP" <<'PY2'
import copy, json, sys
fx = json.load(open(sys.argv[1]))
def ac(c, t, i):
    return {"name": "auto-clear-blocking-labels", "id": i, "status": "completed", "conclusion": c,
            "completed_at": t, "started_at": t}
for p in fx["prs"]:
    p["labels"] = [{"name": "other"}] + ([{"name": "needs-external-review"}] if p["number"] in (1, 3, 4) else [])
fx["autoclear_runs"] = {
    "0000000000000000000000000000000000000002": [ac("failure", "2026-10-14T02:50:00Z", 20), ac("success", "2026-10-14T01:00:00Z", 10)],
    "0000000000000000000000000000000000000005": [ac("success", "2026-10-14T02:55:00Z", 30), ac("failure", "2026-10-14T02:50:00Z", 21)],
}
json.dump(fx, open(f"{sys.argv[2]}/fx-ac.json", "w"))
moved = copy.deepcopy(fx); moved["moved_heads"] = {"3": "0000000000000000000000000000000000000003-moved"}
json.dump(moved, open(f"{sys.argv[2]}/fx-ac-moved.json", "w"))
unread = copy.deepcopy(fx); unread["autoclear_fail_reads"] = ["0000000000000000000000000000000000000002"]
json.dump(unread, open(f"{sys.argv[2]}/fx-ac-unread.json", "w"))
PY2

MCG_RED_PRS=4 CASE_FIXTURE="$TMP/fx-ac.json" run_pass ac-event workflow_run 0000000000000000000000000000000000000001 pull_request ""
check "event pass: green verdicts on labeled PRs are nominated once each; a red one is not" \
  eval '[ "$(nominated)" = "1 3" ] && [ "$(grep -c "^autoclear_prs=" "$TMP/github-output")" = 1 ]'
check "event pass: no auto-clear check-run read is spent (heal nominations are full-pass only)" \
  [ "$(ac_reads)" = 0 ]

MCG_RED_PRS=4 CASE_FIXTURE="$TMP/fx-ac.json" run_pass ac-full workflow_run maintip schedule ""
check "full pass: labeled greens plus the unlabeled green whose newest auto-clear run failed" \
  [ "$(nominated)" = "1 2 3" ]
check "full pass: one auto-clear read per unlabeled green PR, none for labeled or red PRs" \
  [ "$(ac_reads)" = 8 ]

CASE_FIXTURE="$TMP/fx-ac-moved.json" run_pass ac-moved workflow_run maintip schedule ""
check "a verdict turned red because the head moved nominates nothing for that PR" \
  eval '[ "$(nominated)" = "1 2 4" ] && grep -q "generation input changed or unreadable" "$TMP/gh.log"'

CASE_FIXTURE="$TMP/fx-ac-unread.json" run_pass ac-unread workflow_run maintip schedule ""
check "an unreadable auto-clear read nominates nothing for that PR and warns" \
  eval '[ "$(nominated)" = "1 3 4" ] && grep -q "Could not read the auto-clear-blocking-labels check-runs on PR #2" "$TMP/out.log" && [ "$RC" -eq 0 ]'

run_pass ac-unlabeled workflow_run maintip schedule ""
check "unlabeled PRs with no stale auto-clear failure nominate nothing" \
  eval '[ -z "$(nominated)" ] && grep -qx "autoclear_prs=" "$TMP/github-output"'

RL_REMAINING=130 CASE_FIXTURE="$TMP/fx-ac.json" run_pass ac-nothing workflow_run maintip schedule ""
unset RL_REMAINING
check "a pass that evaluated nothing nominates nothing and reads nothing" \
  eval '[ -z "$(nominated)" ] && [ "$(ac_reads)" = 0 ]'

RL_FAIL_PR=3 CASE_FIXTURE="$TMP/fx-ac.json" run_pass ac-stopped workflow_run maintip schedule ""
unset RL_FAIL_PR
check "after a rate-limit stop no auto-clear read is spent; greens posted before it still nominate" \
  eval '[ "$(nominated)" = "1" ] && [ "$(ac_reads)" = 0 ]'

# The nominate-auto-clear job: one dispatch per nominated PR, payload = the PR
# number only, malformed entries ignored, a failed dispatch warns and moves on.
mkdir -p "$TMP/nbin"
cat >"$TMP/nbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NOMINATE_LOG"
case "$*" in *"client_payload[pr]=${NOMINATE_FAIL_PR:-none}"*) echo "HTTP 502" >&2; exit 1 ;; esac
exit 0
SH
chmod +x "$TMP/nbin/gh"
: >"$TMP/nominate.log"
nominate_rc=0
PATH="$TMP/nbin:$PATH" NOMINATE_LOG="$TMP/nominate.log" NOMINATE_FAIL_PR=3 REPO=acme/widget GH_TOKEN=x \
  AUTOCLEAR_PRS="1 3 07 2x 12" bash "$TMP/nominate.sh" >"$TMP/out.log" 2>&1 || nominate_rc=$?
check "nominate job: exactly one auto-clear-evaluate dispatch per valid PR, carrying only its number" \
  eval '[ "$nominate_rc" -eq 0 ] && [ "$(cat "$TMP/nominate.log")" = "$(printf "%s\n" "api -X POST repos/acme/widget/dispatches -f event_type=auto-clear-evaluate -F client_payload[pr]=1" "api -X POST repos/acme/widget/dispatches -f event_type=auto-clear-evaluate -F client_payload[pr]=3" "api -X POST repos/acme/widget/dispatches -f event_type=auto-clear-evaluate -F client_payload[pr]=12")" ]'
check "nominate job: malformed entries are ignored and a failed dispatch only warns" \
  eval 'grep -q "Ignoring malformed auto-clear nomination .07." "$TMP/out.log" && grep -q "Ignoring malformed auto-clear nomination .2x." "$TMP/out.log" && grep -q "Could not dispatch auto-clear-evaluate for PR #3" "$TMP/out.log"'

echo "required-check publisher due-only targeting tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
