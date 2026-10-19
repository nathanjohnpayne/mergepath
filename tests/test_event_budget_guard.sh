#!/usr/bin/env bash
# tests/test_event_budget_guard.sh — the installation-budget guard of the
# event-driven gate workflows (#2286) and the shared reader they use with the
# Required Check Publisher (scripts/workflow/installation-budget.sh).
#
# Every workflow step is extracted from the SHIPPED workflow file (Ruby YAML)
# and run against a fake `gh` that keeps the Checks-API runs it is asked to
# write, so each case observes what the step would leave on the PR head. The
# gate scripts are stubs that record each evaluation; the snapshot driver
# (codex-p1-snapshot-retry.py), the lineage helper
# (gate-api-lineage-blocking.sh), the generation helper and the budget
# library are the real files.
#
# Per workflow, the cases are:
#   below the threshold   the run skips the evaluation, publishes no green,
#                         and leaves the publisher's back-off red (or, for a
#                         relay-free archive-relay source, nothing at all);
#                         a job-native required run is non-failing only when
#                         the Checks-API lineage is confirmed to block;
#   above the threshold   the run evaluates as before;
#   rate limit mid-run    the first installation rate-limit failure stops
#                         every further evaluation call;
#   unreadable budget     the run evaluates as before (the chosen direction,
#                         see installation-budget.sh);
#   after the reset       the back-off red each skip leaves is not due in
#                         the publisher's own due() before the reset and is
#                         due after it (the publisher's due()/retry_after()
#                         functions are extracted from its publish step).
#
# Mutation runs point the *_WORKFLOW / BUDGET_LIB variables at edited copies.
# Variables read only inside eval-ed check expressions, indirectly (${!var})
# or by the sourced due() look unused to ShellCheck.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_WORKFLOW="${RELAY_WORKFLOW:-$ROOT/.github/workflows/codex-feedback-archive-relay.yml}"
P1_WORKFLOW="${P1_WORKFLOW:-$ROOT/.github/workflows/codex-p1-gate.yml}"
CR_WORKFLOW="${CR_WORKFLOW:-$ROOT/.github/workflows/coderabbit-severity-gate.yml}"
MCG_WORKFLOW="${MCG_WORKFLOW:-$ROOT/.github/workflows/merge-clearance-gate.yml}"
AC_WORKFLOW="${AC_WORKFLOW:-$ROOT/.github/workflows/auto-clear-blocking-labels.yml}"
RCP_WORKFLOW="${RCP_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"
BUDGET_LIB="${BUDGET_LIB:-$ROOT/scripts/workflow/installation-budget.sh}"

for tool in ruby jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/event-budget.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /' >&2; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "$(tail -20 "$T/out" 2>/dev/null || true)"; fi; }

# ── extraction ────────────────────────────────────────────────────────────
# extract <workflow> <job> <step name> <dest>: the step's run body to <dest>,
# and its literal env values (never ${{ }} expressions) to <dest>.env.
extract() {
  ruby - "$@" <<'RUBY'
require "yaml"
require "shellwords"
wf, job, name, dest = ARGV
doc = YAML.load_file(wf)
steps = doc.fetch("jobs").fetch(job).fetch("steps")
matches = steps.select { |s| s["name"] == name }
abort("#{wf}: expected one step #{job}/#{name}, found #{matches.length}") unless matches.length == 1
run = matches[0]["run"]
abort("#{wf}: #{job}/#{name} has no run body") unless run.is_a?(String)
File.write(dest, run)
env = (matches[0]["env"] || {}).reject { |_, v| v.to_s.include?("${{") }
File.write(dest + ".env", env.map { |k, v| "export #{k}=#{Shellwords.escape(v.to_s)}\n" }.join)
RUBY
}

mkdir -p "$T/steps"
extract "$RELAY_WORKFLOW" relay "Resolve the source PR and read-only boundary" "$T/steps/relay-source.sh"
extract "$P1_WORKFLOW" codex-p1-gate "Close the PR-head check lease" "$T/steps/p1-close.sh"
extract "$CR_WORKFLOW" coderabbit-severity-gate "Run scripts/coderabbit-severity-gate.sh" "$T/steps/cr-event.sh"
extract "$CR_WORKFLOW" scheduled-sweep "Re-evaluate gate per PR and post check_run" "$T/steps/cr-sweep.sh"
extract "$MCG_WORKFLOW" merge-clearance-gate "Installation budget guard (#2286)" "$T/steps/mcg-budget.sh"
extract "$MCG_WORKFLOW" merge-clearance-gate "Run scripts/merge-clearance-gate.sh" "$T/steps/mcg-gate.sh"
extract "$MCG_WORKFLOW" merge-clearance-gate "Close the required check_run (#841 phase 2)" "$T/steps/mcg-close.sh"
extract "$MCG_WORKFLOW" merge-clearance-gate "Confirm the Checks-API lineage blocks while pending (#2247)" "$T/steps/mcg-lineage.sh"
extract "$MCG_WORKFLOW" merge-clearance-gate "Report gate verdict" "$T/steps/mcg-report.sh"
extract "$AC_WORKFLOW" evaluate-and-clear "Installation budget guard (#2286)" "$T/steps/ac-budget.sh"
extract "$AC_WORKFLOW" evaluate-and-clear "Re-evaluate gate per PR + remove label on pass" "$T/steps/ac-clear.sh"
extract "$RCP_WORKFLOW" publish "Resolve targets, evaluate gates, publish" "$T/steps/rcp-publish.sh"

# The publisher's own retry_after() and due() (#2220), lifted verbatim from
# its publish step so the re-evaluation cases run the shipped back-off.
awk '/^retry_after\(\) \{/ { f=1 } f && /^evaluated=0$/ { exit } f' "$T/steps/rcp-publish.sh" >"$T/steps/rcp-due.sh"
grep -q '^due() {' "$T/steps/rcp-due.sh" || { echo "ERROR: could not lift due() from the publisher" >&2; exit 1; }

# ── work tree: real helpers, stub gates ───────────────────────────────────
W="$T/work"
mkdir -p "$W/scripts/workflow" "$W/scripts/lib" "$T/bin"
cp "$BUDGET_LIB" "$W/scripts/workflow/installation-budget.sh"
cp "$ROOT/scripts/workflow/codex-p1-snapshot-retry.py" "$W/scripts/workflow/"
cp "$ROOT/scripts/workflow/required-check-generation.sh" "$W/scripts/workflow/"
cp "$ROOT/scripts/gate-api-lineage-blocking.sh" "$W/scripts/"
cp "$ROOT/scripts/lib/gh-retry-helpers.sh" "$W/scripts/lib/"
chmod +x "$W/scripts/workflow/codex-p1-snapshot-retry.py" "$W/scripts/gate-api-lineage-blocking.sh"

# stub <name> <rc-var> <pass line>: records "<name> <pr>" in GATE_LOG; mode
# `ratelimit` empties the installation budget (EXHAUSTED) and fails the way gh
# does on it; `pass` prints the verdict line and exits 0; `block` exits 1.
stub() {
  cat >"$W/scripts/$1" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$1" "\${1:-}" >>"\$GATE_LOG"
# EXHAUST_AFTER=1: the bucket runs dry during this evaluation, which itself
# completes normally (the next PR's budget read then finds it empty).
[ "\${EXHAUST_AFTER:-}" != 1 ] || : >"\$EXHAUSTED"
case "\${$2:-pass}" in
  ratelimit) : >"\$EXHAUSTED"; echo "gh: API rate limit exceeded for installation. (HTTP 403)" >&2; exit 2 ;;
  block) echo "$4"; exit 1 ;;
  *) echo "$3"; exit 0 ;;
esac
SH
  chmod +x "$W/scripts/$1"
}
stub merge-clearance-gate.sh MCG_MODE "Merge clearance: PASS — test" "Merge clearance: BLOCKED — test"
stub coderabbit-severity-gate.sh CR_MODE "CodeRabbit blocking-tier unresolved: 0" "CodeRabbit blocking-tier unresolved: 1"
stub codex-p1-gate.sh P1_MODE "Codex P1 unresolved: 0" "Codex P1 unresolved: 1"
stub codex-review-check.sh CRC_MODE "all merge gates pass" "Gate not yet met"
cat >"$W/scripts/review-feedback-surface-fingerprint.sh" <<'SH'
#!/usr/bin/env bash
printf 'fingerprint %s\n' "$1" >>"$GATE_LOG"
if [ -e "$EXHAUSTED" ]; then echo "gh: API rate limit exceeded for installation. (HTTP 403)" >&2; exit 2; fi
echo "stable-surface"
SH
chmod +x "$W/scripts/review-feedback-surface-fingerprint.sh"
printf '#!/bin/sh\necho %s\n' "$(printf 'b%.0s' $(seq 40))" >"$T/bin/git"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/git" "$T/bin/sleep"

# ── fake gh ───────────────────────────────────────────────────────────────
# State: $STATE/runs.json (the Checks-API runs written so far), CALLS (one line
# per call; REJECTED for a call the exhausted budget refused), EXHAUSTED (a
# flag file). The listing a filter=latest read returns is what GitHub selects:
# the caller's own job-native run (NATIVE_RUN_ID, in suite NATIVE_SUITE) and
# the newest Checks-API run of the name on the head (all Checks-API runs share
# suite API_SUITE).
cat >"$T/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, re, subprocess, sys
argv = sys.argv[1:]
state = os.environ["STATE"]
calls = os.environ["CALLS"]
runs_path = os.path.join(state, "runs.json")
runs = json.load(open(runs_path)) if os.path.exists(runs_path) else []
token = os.environ.get("GH_TOKEN", "")
only = os.environ.get("EXHAUST_ONLY_TOKEN", "")
exhausted = os.path.exists(os.environ["EXHAUSTED"]) and (not only or token == only)
NOW = os.environ.get("FAKE_NOW", "2026-10-16T01:00:00Z")

def log(line):
    with open(calls, "a") as f:
        f.write(line + "\n")

def out(body, jq):
    text = json.dumps(body)
    if jq:
        r = subprocess.run(["jq", "-r", jq], input=text, capture_output=True, text=True)
        if r.returncode:
            sys.stderr.write(r.stderr); sys.exit(r.returncode)
        text = r.stdout.rstrip("\n")
    if text:
        print(text)
    sys.exit(0)

if argv[:2] == ["pr", "view"]:
    jq = argv[argv.index("--jq") + 1] if "--jq" in argv else None
    log(f"PRVIEW {argv[2]} token={token}")
    if exhausted:
        log("REJECTED pr view"); sys.stderr.write("gh: API rate limit exceeded for installation. (HTTP 403)\n"); sys.exit(1)
    labels = [{"name": n} for n in os.environ.get("PR_LABELS", "needs-external-review").split(",") if n]
    out({"labels": labels, "headRefOid": os.environ.get("PR_HEAD", "")}, jq)

assert argv and argv[0] == "api", argv
argv = argv[1:]
method, fields, jq, endpoint, include = "GET", {}, None, None, False
i = 0
while i < len(argv):
    a = argv[i]
    if a in ("--paginate", "--slurp", "--silent"):
        i += 1; continue
    if a == "-i":
        include = True; i += 1; continue
    if a in ("-X", "--method"):
        method = argv[i + 1]; i += 2; continue
    if a in ("-f", "-F"):
        k, _, v = argv[i + 1].partition("="); fields[k] = v; i += 2; continue
    if a == "--jq":
        jq = argv[i + 1]; i += 2; continue
    endpoint = a; i += 1
repo = os.environ.get("REPO", "acme/widget")
path = endpoint[len("repos/" + repo):] if endpoint.startswith("repos/" + repo) else endpoint
log(f"{method} {endpoint}{' -i' if include else ''} {json.dumps(fields, sort_keys=True)}")

if method == "GET" and endpoint == "rate_limit" and not include:
    rem = os.environ.get("RL_REMAINING", "1000")
    if rem == "fail":
        sys.stderr.write("HTTP 502\n"); sys.exit(1)
    core, gql = int(rem), int(os.environ.get("RL_GQL_REMAINING", "1000"))
    # RL_HEALTHY_READS=N: the first N reads answer healthy whatever the flag
    # says (the bucket empties between two reads of one run).
    reads_path = os.path.join(state, "rl-reads")
    reads = int(open(reads_path).read()) if os.path.exists(reads_path) else 0
    open(reads_path, "w").write(str(reads + 1))
    healthy_reads = int(os.environ.get("RL_HEALTHY_READS", "0"))
    if exhausted and os.environ.get("RL_AFTER_FAIL") != "healthy" and reads >= healthy_reads:
        core = 0
    out({"resources": {"core": {"remaining": core, "reset": int(os.environ.get("RL_RESET", "1792115400"))},
                       "graphql": {"remaining": gql, "reset": int(os.environ.get("RL_GQL_RESET", "1792116000"))}}}, jq)

if include:
    # A probe: GitHub prints the response headers with -i, refused or not.
    if exhausted:
        print("HTTP/2.0 403 Forbidden\nX-Ratelimit-Limit: 1000\nX-Ratelimit-Remaining: 0\n"
              f"X-Ratelimit-Reset: {os.environ.get('PROBE_RESET', '1792114200')}\nX-Ratelimit-Resource: core\n\n"
              '{"message":"API rate limit exceeded for installation."}')
        sys.exit(1)
    print("HTTP/2.0 200 OK\nX-Ratelimit-Limit: 1000\nX-Ratelimit-Remaining: 900\nX-Ratelimit-Reset: 1792115400\n\n{}")
    sys.exit(0)

if exhausted:
    log("REJECTED " + endpoint)
    sys.stderr.write("gh: API rate limit exceeded for installation. (HTTP 403)\n"); sys.exit(1)

def save():
    json.dump(runs, open(runs_path, "w"))

if method == "POST" and path == "/check-runs":
    run = {"id": 7000 + len(runs), "name": fields["name"], "head_sha": fields["head_sha"],
           "status": fields.get("status", "queued"), "conclusion": fields.get("conclusion"),
           "output": {"title": fields.get("output[title]", ""), "summary": fields.get("output[summary]", "")},
           "external_id": "", "app": {"slug": "github-actions"},
           "check_suite": {"id": int(os.environ.get("API_SUITE", "2"))},
           "details_url": f"https://github.com/{repo}/runs/{7000 + len(runs)}",
           "completed_at": NOW if fields.get("status") == "completed" else None}
    runs.append(run); save(); out(run, jq)
m = re.fullmatch(r"/check-runs/(\d+)", path)
if m and method == "PATCH":
    for run in runs:
        if run["id"] == int(m.group(1)):
            run["status"] = fields.get("status", run["status"])
            run["conclusion"] = fields.get("conclusion", run["conclusion"])
            run["output"] = {"title": fields.get("output[title]", ""), "summary": fields.get("output[summary]", "")}
            run["completed_at"] = NOW
    save(); out({"id": int(m.group(1))}, jq)
if m and method == "GET":
    out(next(r for r in runs if r["id"] == int(m.group(1))), jq)
m = re.fullmatch(r"/commits/([0-9a-f]{40})/check-runs", path)
if m and method == "GET":
    if os.environ.get("LIST_FAIL") == "1":
        sys.stderr.write("HTTP 502\n"); sys.exit(1)
    head, name = m.group(1), fields.get("check_name")
    mine = [r for r in runs if r["head_sha"] == head and (name is None or r["name"] == name)]
    listed = []
    if os.environ.get("NATIVE_RUN_ID") and name:
        listed.append({"id": 1, "name": name, "status": "in_progress", "conclusion": None,
                       "external_id": "0b5e1f3e-native", "app": {"slug": "github-actions"},
                       "check_suite": {"id": int(os.environ.get("NATIVE_SUITE", "1"))},
                       "details_url": f"https://github.com/{repo}/actions/runs/{os.environ['NATIVE_RUN_ID']}/job/9"})
    if fields.get("filter") == "latest":
        mine = sorted(mine, key=lambda r: r["id"])[-1:] if mine else []
    out({"check_runs": listed + mine}, jq)
if method == "GET" and path == "/commits/HEAD":
    out({"sha": "b" * 40}, jq)
m = re.fullmatch(r"/pulls/(\d+)", path)
if m and method == "GET":
    out({"number": int(m.group(1)), "head": {"sha": os.environ.get("PR_HEAD", "")},
         "base": {"sha": "c" * 40, "ref": "main"}, "user": {"login": "nathanjohnpayne"}}, jq)
log("UNEXPECTED " + endpoint)
sys.stderr.write(f"unexpected gh call: {method} {endpoint}\n"); sys.exit(3)
PY
chmod +x "$T/bin/gh"

HEAD="1111111111111111111111111111111111111111"
RESET_ISO="2026-10-16T01:50:00Z"      # RL_RESET 1792115400 (the REST window)
GQL_RESET_ISO="2026-10-16T02:00:00Z"  # RL_GQL_RESET 1792116000
PROBE_ISO="2026-10-16T01:30:00Z"      # PROBE_RESET 1792114200 (a refused call's headers)

# fresh: reset state between cases.
fresh() {
  rm -rf "$T/state"; mkdir -p "$T/state"
  : >"$T/state/calls"; : >"$T/state/gates"; : >"$T/state/output"; : >"$T/state/env"
  rm -f "$T/state/exhausted"
}
# open_lease: the Checks-API hold the event job opened before its guard ran.
open_lease() {  # <name> -> prints id
  (cd "$W" && PATH="$T/bin:$PATH" STATE="$T/state" CALLS="$T/state/calls.setup" EXHAUSTED="$T/state/none" \
    REPO=acme/widget gh api -X POST repos/acme/widget/check-runs -f name="$1" -f head_sha="$HEAD" \
    -f status=in_progress --jq .id)
}
# step <script> [VAR=value ...]: run an extracted step in the work tree with
# its own literal env, the fake gh, and the per-case overrides.
step() {
  local script="$1"; shift
  local rc=0
  (
    cd "$W"
    # shellcheck disable=SC1090
    . "$script.env"
    export PATH="$T/bin:$PATH" STATE="$T/state" CALLS="$T/state/calls" GATE_LOG="$T/state/gates"
    export EXHAUSTED="$T/state/exhausted" GITHUB_OUTPUT="$T/state/output" GITHUB_ENV="$T/state/env"
    export RUNNER_TEMP="$T/state" REPO=acme/widget GH_TOKEN=installation-token
    export GH_RETRY_BACKOFF_SECONDS=0
    for kv in "$@"; do export "${kv?}"; done
    bash -e "$script"
  ) >"$T/out" 2>&1 || rc=$?
  return "$rc"
}
output() { sed -n "s/^$1=//p" "$T/state/output" | tail -1; }
runs_json() { cat "$T/state/runs.json" 2>/dev/null || echo '[]'; }
newest() {  # <name>: "<status>|<conclusion>|<title>" of the newest Checks-API run
  runs_json | jq -r --arg n "$1" '[.[] | select(.name == $n)] | sort_by(.id) | last
    | if . == null then "none" else "\(.status)|\(.conclusion // "-")|\(.output.title)" end'
}
greens() { runs_json | jq '[.[] | select(.conclusion == "success")] | length'; }
gates() { tr '\n' ' ' <"$T/state/gates" | sed 's/ $//'; }
calls_after_gate() {  # the calls made after the first gate-script call
  local n
  n=$(grep -c . "$T/state/calls" || true)
  echo "$n"
}

SHORT="RL_REMAINING=150"   # below every event workflow's evaluation + 200 reserve
PLENTY="RL_REMAINING=900"

echo "── installation-budget.sh ──"
lib() {  # <shell snippet>: run against the library with the fake gh
  (
    cd "$W"
    export PATH="$T/bin:$PATH" STATE="$T/state" CALLS="$T/state/calls" EXHAUSTED="$T/state/exhausted" REPO=acme/widget
    for kv in "${@:2}"; do export "${kv?}"; done
    # shellcheck disable=SC1091
    . scripts/workflow/installation-budget.sh
    eval "$1"
  ) 2>/dev/null
}
fresh
check "reads both buckets and covers an affordable evaluation" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_affordable 1 && echo yes" RL_REMAINING=160 RL_GQL_REMAINING=60)" = yes ]'
check "one request short of evaluation + reserve is not affordable" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_affordable 1 || echo no" RL_REMAINING=159)" = no ]'
check "a short GraphQL bucket alone is not affordable" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_affordable 1 || echo no" RL_REMAINING=900 RL_GQL_REMAINING=59)" = no ]'
check "requests already spent are charged against the snapshot" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; spent=1; ib_affordable 1 || echo no" RL_REMAINING=160)" = no ]'
check "an unreadable /rate_limit is unknown, and unknown is affordable (evaluate as before)" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_affordable 1 && echo \$budget_known" RL_REMAINING=fail)" = 0 ]'
check "a malformed knob is unknown too" \
  '[ "$(lib "ib_read x 100 10 50 >/dev/null; ib_affordable 1 && echo \$budget_known" RL_REMAINING=10)" = 0 ]'
check "capacity counts whole evaluations beyond the reserves" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_capacity" RL_REMAINING=400 RL_GQL_REMAINING=1000)" = 5 ]'
check "capacity with a zero per-evaluation GraphQL cost ignores that bucket" \
  '[ "$(lib "ib_read 2 200 0 0 >/dev/null; ib_capacity" RL_REMAINING=210 RL_GQL_REMAINING=0)" = 5 ]'
check "the short-bucket reset is the REST reset when REST is short" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_short_bucket_reset" RL_REMAINING=100)" = "$RESET_ISO" ]'
check "the short-bucket reset is the GraphQL reset when only GraphQL is short" \
  '[ "$(lib "ib_read 60 100 10 50 >/dev/null; ib_short_bucket_reset" RL_REMAINING=900 RL_GQL_REMAINING=1)" = "$GQL_RESET_ISO" ]'
check "both installation rate-limit wordings are recognised, other errors are not" \
  '[ "$(lib "ib_rate_limited \"gh: API rate limit exceeded for installation\" && ib_rate_limited \"rate limit already exceeded for installation ID 4\" && ! ib_rate_limited \"You have exceeded a secondary rate limit\" && echo ok")" = ok ]'
: >"$T/state/exhausted"
check "a refused probe's X-RateLimit-Reset wins over GET /rate_limit (which can read healthy)" \
  '[ "$(lib "ib_exhausted_reset \"rate limit exceeded for installation\"" RL_AFTER_FAIL=healthy)" = "$PROBE_ISO" ]'
rm -f "$T/state/exhausted"
check "an answered probe falls back to GET /rate_limit's bucket" \
  '[ "$(lib "ib_exhausted_reset \"rate limit exceeded for installation\"")" = "$GQL_RESET_ISO" ]'
check "the back-off title carries the publisher's mark and the reset" \
  '[ "$(lib "ib_backoff_title \"Merge clearance gate\" 2 $RESET_ISO")" = "Merge clearance gate — installation API budget exhausted (rc=2); re-evaluated after $RESET_ISO" ]'

echo "── Codex Feedback Archive Relay ──"
cat >"$T/resolver.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'resolver %s\n' "$2" >>"$GATE_LOG"
if [ "${RESOLVER_MODE:-}" = ratelimit ]; then
  echo "gh: API rate limit exceeded for installation. (HTTP 403)" >&2; exit 3
fi
jq -nc '{publish_head_sha:"1111111111111111111111111111111111111111", is_fork:false, requires_relay:false, pr_actor:"x", source_event:"pull_request", source_head_sha:"1111111111111111111111111111111111111111"}'
SH
chmod +x "$T/resolver.sh"
relay_event() {  # <event> <head repo id> <branch>
  jq -n --arg e "$1" --argjson h "$2" --arg b "$3" \
    '{workflow_run:{id:501, display_title:"Codex P1 Gate relay-v1 PR #41", event:$e,
      repository:{id:100}, head_repository:{id:$h}, head_branch:$b}}' >"$T/relay-event.json"
}
relay() { step "$T/steps/relay-source.sh" GITHUB_EVENT_PATH="$T/relay-event.json" SOURCE_RUN_ID=501 SOURCE_RESOLVER="$T/resolver.sh" "$@"; }
fresh; relay_event pull_request_review 100 feature/x
relay "$SHORT" && rc=0 || rc=$?
check "below the threshold: a same-repository source is not bound and nothing is written" \
  '[ "$rc" = 0 ] && [ -z "$(gates)" ] && [ "$(output source_bound)" = false ] && [ "$(output requires_relay)" = false ] && ! grep -qE "^(POST|PATCH)" "$T/state/calls"'
fresh; relay_event pull_request_review 100 feature/x
relay "$PLENTY" && rc=0 || rc=$?
check "above the threshold: the source is bound as before" '[ "$rc" = 0 ] && [ "$(gates)" = "resolver 41" ] && [ "$(output source_bound)" = true ]'
fresh; relay_event pull_request_review 100 feature/x
relay RL_REMAINING=fail && rc=0 || rc=$?
check "unreadable budget: the source is bound as before" '[ "$rc" = 0 ] && [ "$(gates)" = "resolver 41" ]'
for shape in "fork:pull_request:200:feature/x" "issue_comment:issue_comment:100:main" "Dependabot:pull_request:100:dependabot/github_actions/x"; do
  IFS=: read -r label ev hid br <<<"$shape"
  fresh; relay_event "$ev" "$hid" "$br"
  relay "$SHORT" && rc=0 || rc=$?
  check "below the threshold: a relay-capable $label source is still bound (one-shot archive)" '[ "$rc" = 0 ] && [ "$(gates)" = "resolver 41" ]'
done
fresh; relay_event pull_request 100 feature/x
relay "$PLENTY" RESOLVER_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run, relay-free source: one binding attempt, no retry, no write, green" \
  '[ "$rc" = 0 ] && [ "$(gates)" = "resolver 41" ] && [ "$(output source_bound)" = false ] && ! grep -qE "^(POST|PATCH)" "$T/state/calls"'
fresh; relay_event pull_request 200 feature/x
relay "$PLENTY" RESOLVER_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run, relay-capable source: one binding attempt, then the failure path" '[ "$rc" = 3 ] && [ "$(gates)" = "resolver 41" ]'

echo "── Codex P1 Gate (event job) ──"
p1() {  # runs the close step against a lease opened on HEAD
  local id
  id=$(open_lease "Codex P1 unresolved threads")
  step "$T/steps/p1-close.sh" ARCHIVE_RESULT=success GATE_READY=true FINGERPRINT_AVAILABLE=true \
    LEGACY_BOOTSTRAP=false PR_NUMBER=41 HEAD_SHA="$HEAD" CHECK_ID="$id" RUN_ID=9001 PR_HEAD="$HEAD" "$@"
}
fresh; p1 "$SHORT" NATIVE_RUN_ID=9001 && rc=0 || rc=$?
check "below the threshold: no evaluation; the lease closes with the back-off red; no green" \
  '[ -z "$(gates)" ] && [ "$(newest "Codex P1 unresolved threads")" = "completed|failure|Codex P1 unresolved threads — installation API budget exhausted (rc=2); re-evaluated after $RESET_ISO" ] && [ "$(greens)" = 0 ]'
check "below the threshold: the native run is non-failing because the Checks-API red blocks outside its suite" '[ "$rc" = 0 ]'
P1_BACKOFF_TITLE=$(newest "Codex P1 unresolved threads" | cut -d'|' -f3)
fresh; p1 "$SHORT" NATIVE_RUN_ID=9001 NATIVE_SUITE=2 && rc=0 || rc=$?
check "below the threshold, shared suite: the native run fails (lineage not confirmed)" '[ "$rc" = 1 ] && [ "$(greens)" = 0 ]'
fresh; p1 "$SHORT" NATIVE_RUN_ID=9001 LIST_FAIL=1 && rc=0 || rc=$?
check "below the threshold, unreadable lineage: the native run fails" '[ "$rc" = 1 ] && [ "$(greens)" = 0 ]'
fresh; p1 "$SHORT" && rc=0 || rc=$?
check "below the threshold, native run not on the head (issue_comment): the native run fails" '[ "$rc" = 1 ] && [ "$(greens)" = 0 ]'
fresh; p1 "$PLENTY" NATIVE_RUN_ID=9001 && rc=0 || rc=$?
check "above the threshold: the driver evaluates and publishes the verdict" \
  '[ "$rc" = 0 ] && grep -q "^codex-p1-gate.sh 41" "$T/state/gates" && [ "$(newest "Codex P1 unresolved threads" | cut -d"|" -f1-2)" = "completed|success" ]'
fresh; p1 RL_REMAINING=fail NATIVE_RUN_ID=9001 && rc=0 || rc=$?
check "unreadable budget: the driver evaluates as before" '[ "$rc" = 0 ] && grep -q "^codex-p1-gate.sh 41" "$T/state/gates"'
# A successful driver cannot erase the existing pipeline failure from tee.
cat >"$T/bin/tee" <<'TEE_FAILURE'
#!/usr/bin/env bash
cat >/dev/null
exit 46
TEE_FAILURE
chmod +x "$T/bin/tee"
fresh; p1 "$PLENTY" NATIVE_RUN_ID=9001 && rc=0 || rc=$?
check "a failed driver-output capture remains a native step failure" '[ "$rc" = 46 ]'
rm -f "$T/bin/tee"
fresh; p1 "$PLENTY" NATIVE_RUN_ID=9001 P1_MODE=ratelimit RL_AFTER_FAIL=healthy EXHAUST_ONLY_TOKEN=nobody && rc=0 || rc=$?
check "rate limit mid-run: the gate runs once and no fingerprint or gate call follows it" \
  '[ "$(grep -c "^codex-p1-gate.sh" "$T/state/gates")" = 1 ] && [ "$(sed -n "/^codex-p1-gate.sh/,\$p" "$T/state/gates" | grep -c "^fingerprint")" = 0 ]'
check "rate limit mid-run: the lease is closed red, never green, and the native run follows the lineage" \
  '[ "$(newest "Codex P1 unresolved threads" | cut -d"|" -f1-2)" = "completed|failure" ] && [ "$(greens)" = 0 ] && [ "$rc" = 0 ]'
check "rate limit mid-run: the lease carries the back-off title, so the publisher backs it off until the reset" \
  'newest "Codex P1 unresolved threads" | grep -q "^completed|failure|Codex P1 unresolved threads — installation API budget exhausted (rc=2); re-evaluated after "'
fresh; p1 "$PLENTY" NATIVE_RUN_ID=9001 P1_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run with every call refused: the lease stays in progress (blocking), no green, native fails" \
  '[ "$(newest "Codex P1 unresolved threads" | cut -d"|" -f1)" = in_progress ] && [ "$(greens)" = 0 ] && [ "$rc" = 1 ]'

echo "── CodeRabbit Severity Gate ──"
cr() { step "$T/steps/cr-event.sh" PR_NUMBER=41 HEAD_SHA="$HEAD" RUN_ID=9002 "$@"; }
fresh; cr "$SHORT" NATIVE_RUN_ID=9002 && rc=0 || rc=$?
check "below the threshold: no evaluation; one back-off red is posted; no green" \
  '[ -z "$(gates)" ] && [ "$(newest "CodeRabbit unresolved blocking findings")" = "completed|failure|CodeRabbit unresolved blocking findings — installation API budget exhausted (rc=2); re-evaluated after $RESET_ISO" ] && [ "$(greens)" = 0 ] && [ "$rc" = 0 ]'
CR_BACKOFF_TITLE=$(newest "CodeRabbit unresolved blocking findings" | cut -d'|' -f3)
fresh; cr "$SHORT" NATIVE_RUN_ID=9002 NATIVE_SUITE=2 && rc=0 || rc=$?
check "below the threshold, shared suite: the native run fails" '[ "$rc" = 1 ] && [ "$(greens)" = 0 ]'
fresh; cr "$SHORT" && rc=0 || rc=$?
check "below the threshold, native run not listed: the native run fails" '[ "$rc" = 1 ]'
for ro in IS_FORK=true "PR_ACTOR=dependabot[bot]"; do
  fresh; cr "$SHORT" NATIVE_RUN_ID=9002 "$ro" && rc=0 || rc=$?
  check "below the threshold, read-only run ($ro): evaluates as before and posts nothing (Codex P1 on #2298)" \
    '[ "$rc" = 0 ] && [ "$(gates)" = "coderabbit-severity-gate.sh 41" ] && [ "$(newest "CodeRabbit unresolved blocking findings")" = none ]'
done
fresh; cr "$PLENTY" NATIVE_RUN_ID=9002 IS_FORK=true CR_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run, read-only run: fails as before, no write attempted" \
  '[ "$rc" = 1 ] && ! grep -qE "^POST" "$T/state/calls"'
fresh; cr "$PLENTY" NATIVE_RUN_ID=9002 && rc=0 || rc=$?
check "above the threshold: the gate evaluates and writes nothing to the Checks API" \
  '[ "$rc" = 0 ] && [ "$(gates)" = "coderabbit-severity-gate.sh 41" ] && [ "$(newest "CodeRabbit unresolved blocking findings")" = none ]'
fresh; cr RL_REMAINING=fail NATIVE_RUN_ID=9002 && rc=0 || rc=$?
check "unreadable budget: the gate evaluates as before" '[ "$rc" = 0 ] && [ "$(gates)" = "coderabbit-severity-gate.sh 41" ]'
fresh; cr "$PLENTY" NATIVE_RUN_ID=9002 CR_MODE=block && rc=0 || rc=$?
check "above the threshold, a real block still fails the native run" '[ "$rc" = 1 ] && [ "$(newest "CodeRabbit unresolved blocking findings")" = none ]'
fresh; cr "$PLENTY" NATIVE_RUN_ID=9002 CR_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run: one gate call, then only the back-off write and the lineage read" \
  '[ "$(gates)" = "coderabbit-severity-gate.sh 41" ] && [ "$(grep -c REJECTED "$T/state/calls")" -le 2 ]'
check "rate limit mid-run: the back-off red carries the refused probe's reset when it lands" \
  '[ "$(greens)" = 0 ] && { [ "$(newest "CodeRabbit unresolved blocking findings")" = none ] || newest "CodeRabbit unresolved blocking findings" | grep -qF "re-evaluated after $PROBE_ISO"; }'
check "rate limit mid-run with every write refused: the native run fails (nothing confirms a block)" '[ "$rc" = 1 ]'
fresh; cr "$PLENTY" NATIVE_RUN_ID=9002 CR_MODE=ratelimit RL_AFTER_FAIL=healthy EXHAUST_ONLY_TOKEN=nobody && rc=0 || rc=$?
check "rate limit mid-run, writes still landing: the back-off red is posted and the native run is non-failing" \
  '[ "$rc" = 0 ] && [ "$(gates)" = "coderabbit-severity-gate.sh 41" ] && newest "CodeRabbit unresolved blocking findings" | grep -q "^completed|failure|CodeRabbit unresolved blocking findings — installation API budget exhausted (rc=2); re-evaluated after " && [ "$(greens)" = 0 ]'

echo "── CodeRabbit Severity Gate (issue_comment path) ──"
crs() { step "$T/steps/cr-sweep.sh" PRS=41 PR_HEAD="$HEAD" "$@"; }
fresh; crs EVENT_NAME=issue_comment "$SHORT" && rc=0 || rc=$?
check "below the threshold: no evaluation and no generation; the head gets the back-off red; green run" \
  '[ "$rc" = 0 ] && [ -z "$(gates)" ] && [ "$(newest "CodeRabbit unresolved blocking findings")" = "completed|failure|CodeRabbit unresolved blocking findings — installation API budget exhausted (rc=2); re-evaluated after $RESET_ISO" ] && [ "$(greens)" = 0 ]'
fresh; crs EVENT_NAME=issue_comment "$PLENTY" && rc=0 || rc=$?
check "above the threshold: the commented PR is evaluated" 'grep -q "^coderabbit-severity-gate.sh 41" "$T/state/gates"'
fresh; crs EVENT_NAME=schedule "$SHORT" && rc=0 || rc=$?
check "the scheduled sweep is not guarded (it is the backstop)" 'grep -q "^coderabbit-severity-gate.sh 41" "$T/state/gates"'
fresh; crs EVENT_NAME=issue_comment RL_REMAINING=fail && rc=0 || rc=$?
check "unreadable budget: the commented PR is evaluated as before" 'grep -q "^coderabbit-severity-gate.sh 41" "$T/state/gates"'
fresh; crs EVENT_NAME=issue_comment "$PLENTY" CR_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run: the gate runs once, nothing after it, the generation stays in progress, green run" \
  '[ "$rc" = 0 ] && [ "$(gates)" = "coderabbit-severity-gate.sh 41" ] && [ "$(newest "CodeRabbit unresolved blocking findings" | cut -d"|" -f1)" = in_progress ] && ! grep -q REJECTED "$T/state/calls" && [ "$(greens)" = 0 ]'

echo "── Merge Clearance Gate (event job) ──"
# mcg: run budget → gate (unless skipped) → close → lineage (when its pinned
# condition holds) → report, threading step outputs the way Actions does.
mcg() {
  local id rc skip pending rl api=""
  id=$(open_lease "Merge clearance gate")
  : >"$T/state/output"
  step "$T/steps/mcg-budget.sh" OPEN_ID="$id" "$@" || true
  skip=$(output skip); local title; title=$(output title)
  : >"$T/state/output"
  if [ "$skip" != true ]; then
    step "$T/steps/mcg-gate.sh" PR_NUMBER=41 "$@" || true
  fi
  local grc gverdict gtitle
  grc=$(output rc); gverdict=$(output verdict); pending=$(output pending); rl=$(output rate_limited); gtitle=$(output budget_title)
  step "$T/steps/mcg-close.sh" PR_NUMBER=41 CHECK_ID="$id" HEAD_SHA="$HEAD" PR_HEAD="$HEAD" RC="$grc" VERDICT="$gverdict" \
    BUDGET_SKIP="$skip" BUDGET_SKIP_TITLE="$title" RATE_LIMITED="$rl" RATE_LIMITED_TITLE="$gtitle" "$@" || true
  : >"$T/state/output"
  if [ "$pending" = true ] || [ "$skip" = true ] || [ "$rl" = true ]; then
    step "$T/steps/mcg-lineage.sh" HEAD_SHA="$HEAD" RUN_ID=9003 "$@" || true
    api=$(output api_blocking)
  fi
  rc=0
  step "$T/steps/mcg-report.sh" RC="$grc" VERDICT="$gverdict" PENDING="$pending" API_BLOCKING="$api" \
    BUDGET_SKIP="$skip" RATE_LIMITED="$rl" "$@" || rc=$?
  return "$rc"
}
fresh; mcg "$SHORT" NATIVE_RUN_ID=9003 && rc=0 || rc=$?
check "below the threshold: no evaluation; the hold closes with the back-off red; no green" \
  '[ -z "$(gates)" ] && [ "$(newest "Merge clearance gate")" = "completed|failure|Merge clearance gate — installation API budget exhausted (rc=2); re-evaluated after $RESET_ISO" ] && [ "$(greens)" = 0 ]'
check "below the threshold: the native run is non-failing because the red blocks outside its suite" '[ "$rc" = 0 ]'
check "below the threshold: phase 2 spends no read before closing the hold" '! grep -qE "^(PRVIEW|GET repos/acme/widget/commits/HEAD)" "$T/state/calls"'
MCG_BACKOFF_TITLE=$(newest "Merge clearance gate" | cut -d'|' -f3)
fresh; mcg "$SHORT" NATIVE_RUN_ID=9003 NATIVE_SUITE=2 && rc=0 || rc=$?
check "below the threshold, shared suite: the native run fails" '[ "$rc" = 1 ] && [ "$(greens)" = 0 ]'
fresh; mcg "$PLENTY" NATIVE_RUN_ID=9003 && rc=0 || rc=$?
check "above the threshold: the gate evaluates and the hold closes green" \
  '[ "$rc" = 0 ] && [ "$(gates)" = "merge-clearance-gate.sh 41" ] && [ "$(newest "Merge clearance gate" | cut -d"|" -f1-2)" = "completed|success" ]'
fresh; mcg RL_REMAINING=fail NATIVE_RUN_ID=9003 && rc=0 || rc=$?
check "unreadable budget: the gate evaluates as before" '[ "$rc" = 0 ] && [ "$(gates)" = "merge-clearance-gate.sh 41" ]'
fresh; mcg "$PLENTY" NATIVE_RUN_ID=9003 MCG_MODE=block && rc=0 || rc=$?
check "above the threshold, a real block still fails the native run" '[ "$rc" = 1 ] && [ "$(newest "Merge clearance gate" | cut -d"|" -f1-2)" = "completed|failure" ]'
fresh; mcg "$PLENTY" NATIVE_RUN_ID=9003 MCG_MODE=ratelimit && rc=0 || rc=$?
check "rate limit mid-run: one gate call and no phase-2 read after it" \
  '[ "$(gates)" = "merge-clearance-gate.sh 41" ] && ! grep -qE "^(PRVIEW|GET repos/acme/widget/commits/HEAD)" "$T/state/calls" && [ "$(greens)" = 0 ]'
fresh; mcg "$PLENTY" NATIVE_RUN_ID=9003 MCG_MODE=ratelimit RL_AFTER_FAIL=healthy EXHAUST_ONLY_TOKEN=nobody && rc=0 || rc=$?
check "rate limit mid-run, writes still landing: the hold closes with the probe-reset back-off red and the native run is non-failing" \
  '[ "$rc" = 0 ] && [ "$(newest "Merge clearance gate" | cut -d"|" -f1-2)" = "completed|failure" ]'
fresh
id=$(open_lease "Merge clearance gate")
: >"$T/state/exhausted"
step "$T/steps/mcg-gate.sh" PR_NUMBER=41 MCG_MODE=ratelimit RL_AFTER_FAIL=healthy || true
check "rate limit mid-run: the back-off title carries the refused probe's reset, not /rate_limit's" \
  '[ "$(output budget_title)" = "Merge clearance gate — installation API budget exhausted (rc=2); re-evaluated after $PROBE_ISO" ]'

echo "── Auto-clear blocking labels ──"
fresh; step "$T/steps/ac-budget.sh" "$SHORT" && rc=0 || rc=$?
check "below the threshold: the guard says skip (nothing after it runs)" '[ "$rc" = 0 ] && [ "$(output skip)" = true ] && [ "$(grep -c . "$T/state/calls")" = 1 ]'
fresh; step "$T/steps/ac-budget.sh" "$PLENTY" && rc=0 || rc=$?
check "above the threshold: no skip" '[ "$rc" = 0 ] && [ -z "$(output skip)" ]'
fresh; step "$T/steps/ac-budget.sh" RL_REMAINING=fail && rc=0 || rc=$?
check "unreadable budget: no skip" '[ "$rc" = 0 ] && [ -z "$(output skip)" ]'
check "the event job's later steps are gated on the guard and the stop" \
  'ruby -ryaml -e '"'"'s = YAML.load_file(ARGV[0])["jobs"]["evaluate-and-clear"]["steps"]; r = s.find { |x| x["name"] == "Resolve PR number from event" }; c = s.find { |x| x["name"] == "Continue approved PRs after completed checks" }; exit((r["if"].to_s.include?("steps.budget.outputs.skip != '"'"'"'"'"'"'"'true'"'"'"'"'"'"'"'") && c["if"].to_s.include?("steps.clear.outputs.budget_stopped")) ? 0 : 1)'"'"' "$AC_WORKFLOW"'
check "the */5 sweep that re-evaluates a skipped PR carries no budget guard" \
  'ruby -ryaml -e '"'"'j = YAML.load_file(ARGV[0])["jobs"]["scheduled-sweep"]; exit(j.to_s.include?("installation-budget") ? 1 : 0)'"'"' "$AC_WORKFLOW"'
ac_clear() {
  step "$T/steps/ac-clear.sh" PR_NUMBERS="$(printf '41\n42')" PR_HEAD="$HEAD" GH_TOKEN=pat-token \
    WORKFLOW_TOKEN=installation-token EXHAUST_ONLY_TOKEN=installation-token AUTHOR_TOKEN= \
    QUEUE_POLICY_TOKEN= QUEUE_SOURCE_TOKEN= DEFAULT_BRANCH=main EVENT_NAME=workflow_run EVENT_ACTION=completed "$@"
}
fresh; : >"$T/state/exhausted"; ac_clear && rc=0 || rc=$?
check "budget already short inside the step: no PR is evaluated or written, and nothing is an infra error" \
  '[ "$rc" = 0 ] && ! grep -q "^PRVIEW" "$T/state/calls" && [ -z "$(gates)" ] && [ "$(output budget_stopped)" = true ] && grep -q "^HAD_INFRA_ERROR=0" "$T/state/env"'
fresh; : >"$T/state/exhausted"; ac_clear RL_HEALTHY_READS=1 && rc=0 || rc=$?
check "rate limit mid-run: PR 41 fails on the exhausted installation token and PR 42 is never read" \
  '[ "$(grep -c "^PRVIEW 41" "$T/state/calls")" -ge 1 ] && ! grep -q "^PRVIEW 42" "$T/state/calls" && [ -z "$(gates)" ] && [ "$(output budget_stopped)" = true ]'
check "rate limit mid-run: the failed PR keeps its infra error; the budget never reclassifies it (Codex P2 on #2298)" \
  '[ "$rc" = 1 ] && grep -q "^HAD_INFRA_ERROR=1" "$T/state/env" && grep -q "^HAD_INFRA_ERROR_PRS=41$" "$T/state/env"'
fresh; ac_clear CRC_MODE=block EXHAUST_AFTER=1 && rc=0 || rc=$?
check "budget runs dry during a clean evaluation: the next PR is not evaluated, no failure recorded (Codex P2 on #2298)" \
  '[ "$rc" = 0 ] && [ "$(gates)" = "codex-review-check.sh 41" ] && ! grep -q "^PRVIEW 42" "$T/state/calls" && [ "$(output budget_stopped)" = true ] && grep -q "^HAD_INFRA_ERROR=0" "$T/state/env"'
fresh; : >"$T/state/exhausted"; ac_clear RL_AFTER_FAIL=healthy && rc=0 || rc=$?
check "a failure with the budget still healthy stays an infra error and the next PR is evaluated" \
  '[ "$rc" = 1 ] && grep -q "^PRVIEW 42" "$T/state/calls" && grep -q "^HAD_INFRA_ERROR=1" "$T/state/env" && [ -z "$(output budget_stopped)" ]'
fresh; : >"$T/state/exhausted"; ac_clear RL_REMAINING=fail && rc=0 || rc=$?
check "a failure with the budget unreadable stays an infra error and the next PR is evaluated" \
  '[ "$rc" = 1 ] && grep -q "^PRVIEW 42" "$T/state/calls" && grep -q "^HAD_INFRA_ERROR=1" "$T/state/env" && [ -z "$(output budget_stopped)" ]'
fresh; ac_clear "$PLENTY" CRC_MODE=block && rc=0 || rc=$?
check "above the threshold: both PRs are evaluated" '[ "$rc" = 0 ] && [ "$(gates)" = "codex-review-check.sh 41 codex-review-check.sh 42" ]'

echo "── re-evaluation after the reset (the publisher's due()) ──"
# Each skip path's back-off red, as the newest run of its context with the
# other two contexts current and green, against the publisher's shipped due().
due_case() {  # <context> <title> <pass start> -> prints "due" or "not-due <reason>"
  local ctx="$1" title="$2" start="$3"
  jq -n --arg c "$ctx" --arg t "$title" --arg h "$HEAD" '
    ["Merge clearance gate","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings"]
    | to_entries | map(
        if .value == $c then {name:.value, head_sha:$h, id:(100 + .key), status:"completed", conclusion:"failure",
                              completed_at:"2026-10-16T01:00:00Z", output:{title:$t}, details_url:"https://x/runs/1"}
        else {name:.value, head_sha:$h, id:(100 + .key), status:"completed", conclusion:"success",
              completed_at:"2026-10-16T01:00:00Z", output:{title:"ok"}, details_url:"https://x/runs/1"} end)' \
    >"$T/state/runs.json"
  (
    cd "$W"
    export PATH="$T/bin:$PATH" STATE="$T/state" CALLS="$T/state/calls" EXHAUSTED="$T/state/none" REPO=acme/widget
    export MCG_CONTEXT="Merge clearance gate" CODEX_P1_CONTEXT="Codex P1 unresolved threads"
    export CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings"
    RATE_LIMIT_MARK="installation API budget exhausted"; PASS_START="$start"
    stale_before="2026-10-16T00:00:00Z"; DUE_MAX_AGE_SECONDS=1800
    # shellcheck disable=SC1091
    . "$T/steps/rcp-due.sh"
    if due "$HEAD" "2026-10-16T00:30:00Z"; then echo due; else echo "not-due $DUE_REASON"; fi
  )
}
fresh
check "control: the lifted due() reads the fixture (three greens are current, not due)" \
  '[ "$(due_case "none" "ok" "2026-10-16T01:10:00Z")" = "not-due current" ]'
for pair in "Codex P1 unresolved threads|P1_BACKOFF_TITLE" "CodeRabbit unresolved blocking findings|CR_BACKOFF_TITLE" "Merge clearance gate|MCG_BACKOFF_TITLE"; do
  ctx=${pair%%|*}; var=${pair#*|}; title=${!var}
  fresh
  before=$(due_case "$ctx" "$title" "2026-10-16T01:10:00Z")
  after=$(due_case "$ctx" "$title" "2026-10-16T01:51:00Z")
  check "$ctx: the skip's back-off red is not due before the reset" '[ "$before" = "not-due backoff $RESET_ISO" ]'
  check "$ctx: and is due on the first publisher pass after it" '[ "$after" = due ]'
done

echo
echo "event budget guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
