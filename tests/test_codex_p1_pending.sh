#!/usr/bin/env bash
# tests/test_codex_p1_pending.sh — the #2618 pending arm of the event-driven
# `Codex P1 unresolved threads` job (the #2247 treatment, extended).
#
# The SHIPPED "Close the PR-head check lease" step is extracted from
# .github/workflows/codex-p1-gate.yml (Ruby YAML) and run with the REAL
# snapshot driver (codex-p1-snapshot-retry.py), the REAL gate script
# (codex-p1-gate.sh and the libraries it sources), the REAL lineage helper
# (gate-api-lineage-blocking.sh) and the trusted review policy, against a
# fake `gh` that keeps every Checks-API run written to it. Only the feedback
# accounting answer and the surface fingerprint are stubs, so each case
# chooses what accounting reports.
#
# Branch protection is modelled the way #2254 measured it (#828, #835,
# #2232): every check suite's latest run of the required context must pass.
# The Checks-API runs share one suite; every event run's job-native run sits
# in a suite of its own and concludes from the step's exit code. A head is
# BLOCKED while any of those is red or in progress.
#
# Acceptance cases (owner decision on #2618):
#   (a) a non-blocking finding awaiting disposition: the native run is
#       non-failing, the Checks-API lineage is red, the head is BLOCKED;
#   (b) the disposition arrives: the next event clears the head with no
#       rerun of the earlier run (and the control shows the stale native
#       failure a blocking-tier window leaves, which still needs one);
#   (c) a blocking-tier finding (with dispositions also missing, or an open
#       blocking-tier thread) still fails the native run;
#   (d) an unknown tier, a malformed answer, and every read/API error still
#       fail it; so does any pending verdict the lineage cannot confirm, a
#       pending verdict from a drifted snapshot attempt, and a failed lease
#       PATCH.
#
# Mutation runs point P1_WORKFLOW / GATE_SCRIPT / DRIVER at edited copies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P1_WORKFLOW="${P1_WORKFLOW:-$ROOT/.github/workflows/codex-p1-gate.yml}"
GATE_SCRIPT="${GATE_SCRIPT:-$ROOT/scripts/codex-p1-gate.sh}"
DRIVER="${DRIVER:-$ROOT/scripts/workflow/codex-p1-snapshot-retry.py}"

for tool in ruby jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-p1-pending.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /' >&2; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "$(tail -25 "$T/out" 2>/dev/null || true)"; fi; }

# ── extraction ────────────────────────────────────────────────────────────
ruby - "$P1_WORKFLOW" "$T/close.sh" <<'RUBY'
require "yaml"
require "shellwords"
wf, dest = ARGV
steps = YAML.load_file(wf).fetch("jobs").fetch("codex-p1-gate").fetch("steps")
matches = steps.select { |s| s["name"] == "Close the PR-head check lease" }
abort("#{wf}: expected one close step, found #{matches.length}") unless matches.length == 1
File.write(dest, matches[0].fetch("run"))
env = (matches[0]["env"] || {}).reject { |_, v| v.to_s.include?("${{") }
File.write(dest + ".env", env.map { |k, v| "export #{k}=#{Shellwords.escape(v.to_s)}\n" }.join)
RUBY

# ── work tree: the trusted checkout ───────────────────────────────────────
W="$T/work"
mkdir -p "$W/scripts/workflow" "$W/scripts/lib" "$W/.github" "$T/bin"
cp "$GATE_SCRIPT" "$W/scripts/codex-p1-gate.sh"
cp "$DRIVER" "$W/scripts/workflow/codex-p1-snapshot-retry.py"
cp "$ROOT/scripts/gate-api-lineage-blocking.sh" "$W/scripts/"
cp "$ROOT/scripts/workflow/installation-budget.sh" "$W/scripts/workflow/"
for lib in feedback-policy-helpers.sh gh-api-array.sh gh-api-scalar.sh; do
  cp "$ROOT/scripts/lib/$lib" "$W/scripts/lib/"
done
cp "$ROOT/.github/review-policy.yml" "$W/.github/review-policy.yml"
# This suite exercises the legacy scan, so its fixture enables it. A consumer's
# own policy is per-repo config the sync does not carry: it may leave
# codex.p1_gate out or set it false, while the hub's enables it. Replace any
# existing stanza under codex: with one that is enabled.
grep -Eq '^codex:' "$W/.github/review-policy.yml" \
  || { echo "ERROR: the trusted policy has no codex: block; update this test" >&2; exit 1; }
# The stanza takes the codex block's own child indentation (two spaces in
# every consumer today, but any width is valid YAML), and its key twice that.
ind=$(awk '/^codex:/ { c = 1; next } c && /^[^[:space:]#]/ { exit }
  c && /^[[:space:]]+[^[:space:]#]/ { match($0, /^ +/); print RLENGTH; exit }' "$W/.github/review-policy.yml")
[ -n "$ind" ] || ind=2
awk -v ind="$ind" '
  BEGIN { pad = sprintf("%" ind "s", ""); kid = sprintf("%" (2 * ind) "s", "") }
  /^codex:/ { print; print pad "p1_gate:"; print kid "enabled: true"; in_codex = 1; next }
  in_codex && /^[^[:space:]#]/ { in_codex = 0; skip = 0 }
  in_codex && index($0, pad "p1_gate:") == 1 { skip = 1; next }
  # The old stanza runs to the next sibling key: blank lines, comments and
  # deeper lines inside it all go with it.
  skip && index($0, pad) == 1 && substr($0, ind + 1, 1) ~ /[^[:space:]#]/ { skip = 0 }
  skip { next }
  { print }
' "$W/.github/review-policy.yml" >"$W/.github/review-policy.yml.new" \
  && mv "$W/.github/review-policy.yml.new" "$W/.github/review-policy.yml"
# Exactly one enabled key under codex.p1_gate, and it is true.
p1_enabled=$(awk -v ind="$ind" '
  BEGIN { pad = sprintf("%" ind "s", ""); kid = sprintf("%" (2 * ind) "s", "") }
  /^codex:/ { c = 1; next }
  c && /^[^[:space:]#]/ { c = 0 }
  c && index($0, pad "p1_gate:") == 1 { g = 1; next }
  g && index($0, pad) == 1 && substr($0, ind + 1, 1) ~ /[^[:space:]#]/ { g = 0 }
  g && index($0, kid "enabled:") == 1 { v = substr($0, length(kid) + 9); sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v); print v }
' "$W/.github/review-policy.yml")
[ "$p1_enabled" = true ] \
  || { echo "ERROR: could not enable codex.p1_gate in the fixture policy (got '$p1_enabled'); update this test" >&2; exit 1; }
chmod +x "$W/scripts/codex-p1-gate.sh" "$W/scripts/workflow/codex-p1-snapshot-retry.py" \
  "$W/scripts/gate-api-lineage-blocking.sh"

# Accounting stub: answers from $STATE/accounting (first line: rc, rest: the
# JSON answer). ACCOUNTING_SEQ: one answer file per call, consumed in order,
# for the drifted-attempt case.
cat >"$T/accounting.sh" <<'SH'
#!/usr/bin/env bash
src="$STATE/accounting"
if [ -s "$STATE/accounting-seq" ]; then
  src=$(head -1 "$STATE/accounting-seq")
  tail -n +2 "$STATE/accounting-seq" >"$STATE/accounting-seq.next"
  mv "$STATE/accounting-seq.next" "$STATE/accounting-seq"
fi
echo "accounting $1" >>"$STATE/gates"
rc=$(head -1 "$src")
tail -n +2 "$src"
exit "$rc"
SH
# Fingerprint stub: stable unless $STATE/fingerprints lists answers in order.
cat >"$W/scripts/review-feedback-surface-fingerprint.sh" <<'SH'
#!/usr/bin/env bash
if [ -s "$STATE/fingerprints" ]; then
  head -1 "$STATE/fingerprints"
  tail -n +2 "$STATE/fingerprints" >"$STATE/fingerprints.next"
  mv "$STATE/fingerprints.next" "$STATE/fingerprints"
  exit 0
fi
echo stable-surface
SH
chmod +x "$T/accounting.sh" "$W/scripts/review-feedback-surface-fingerprint.sh"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/sleep"

# ── fake gh ───────────────────────────────────────────────────────────────
cat >"$T/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, re, subprocess, sys
argv = sys.argv[1:]
state = os.environ["STATE"]
runs_path = os.path.join(state, "runs.json")
runs = json.load(open(runs_path)) if os.path.exists(runs_path) else []
repo = os.environ.get("REPO", "acme/widget")
head = os.environ["PR_HEAD"]

def log(line):
    with open(os.path.join(state, "calls"), "a") as f:
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

assert argv and argv[0] == "api", argv
argv = argv[1:]
method, fields, jq, endpoint = "GET", {}, None, None
i = 0
while i < len(argv):
    a = argv[i]
    if a in ("--paginate", "--slurp", "--silent"):
        i += 1; continue
    if a in ("-X", "--method"):
        method = argv[i + 1]; i += 2; continue
    if a in ("-f", "-F"):
        k, _, v = argv[i + 1].partition("="); fields[k] = v; i += 2; continue
    if a == "--jq":
        jq = argv[i + 1]; i += 2; continue
    endpoint = a; i += 1
path = endpoint[len("repos/" + repo):] if endpoint.startswith("repos/" + repo) else endpoint
log(f"{method} {endpoint} {json.dumps({k: v for k, v in fields.items() if k != 'query'}, sort_keys=True)}")

def save():
    json.dump(runs, open(runs_path, "w"))

if method == "GET" and endpoint == "rate_limit":
    out({"resources": {"core": {"remaining": 5000, "reset": 1792115400},
                       "graphql": {"remaining": 5000, "reset": 1792116000}}}, jq)
if endpoint == "graphql":
    if os.environ.get("GRAPHQL_FAIL") == "1":
        sys.stderr.write("HTTP 502: Bad Gateway\n"); sys.exit(1)
    threads = json.loads(os.environ.get("THREADS", "[]"))
    out({"data": {"repository": {"pullRequest": {"reviewThreads": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [{"id": f"T{n}", "isResolved": t["resolved"],
                   "comments": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                "nodes": [{"databaseId": c} for c in t["ids"]]}}
                  for n, t in enumerate(threads)]}}}}}, jq)
m = re.fullmatch(r"/pulls/(\d+)/comments", path)
if m and method == "GET":
    if os.environ.get("COMMENTS_FAIL") == "1":
        sys.stderr.write("HTTP 502: Bad Gateway\n"); sys.exit(1)
    out(json.loads(os.environ.get("COMMENTS", "[]")), jq)
m = re.fullmatch(r"/pulls/(\d+)", path)
if m and method == "GET":
    out({"number": int(m.group(1)), "head": {"sha": head}, "user": {"login": "nathanjohnpayne"}}, jq)
if method == "POST" and path == "/check-runs":
    run = {"id": 7000 + len(runs), "name": fields["name"], "head_sha": fields["head_sha"],
           "status": fields.get("status", "queued"), "conclusion": fields.get("conclusion"),
           "output": {"title": fields.get("output[title]", ""), "summary": fields.get("output[summary]", "")},
           "external_id": "", "app": {"slug": "github-actions"}, "check_suite": {"id": 2},
           "details_url": f"https://github.com/{repo}/runs/{7000 + len(runs)}"}
    runs.append(run); save(); out(run, jq)
m = re.fullmatch(r"/check-runs/(\d+)", path)
if m and method == "PATCH":
    if os.environ.get("PATCH_FAIL") == "1":
        sys.stderr.write("HTTP 502: Bad Gateway\n"); sys.exit(1)
    for run in runs:
        if run["id"] == int(m.group(1)):
            run["status"] = fields.get("status", run["status"])
            run["conclusion"] = fields.get("conclusion", run["conclusion"])
            run["output"] = {"title": fields.get("output[title]", ""), "summary": fields.get("output[summary]", "")}
    save(); out({"id": int(m.group(1))}, jq)
m = re.fullmatch(r"/commits/([0-9a-f]{40})/check-runs", path)
if m and method == "GET":
    if os.environ.get("LIST_FAIL") == "1":
        sys.stderr.write("HTTP 502\n"); sys.exit(1)
    sha, name = m.group(1), fields.get("check_name")
    api = [r for r in runs if r["head_sha"] == sha and r["name"] == name]
    api = sorted(api, key=lambda r: r["id"])[-1:] if api else []
    listed = []
    # The calling run's own job-native run, in progress while the step runs.
    # ON_HEAD=0 models an issue_comment run, whose native check is attached
    # to the default branch and never listed on the PR head.
    if os.environ.get("ON_HEAD", "1") == "1":
        listed.append({"id": 1, "name": name, "status": "in_progress", "conclusion": None,
                       "external_id": "0b5e1f3e-native", "app": {"slug": "github-actions"},
                       "check_suite": {"id": int(os.environ.get("NATIVE_SUITE", "100"))},
                       "details_url": f"https://github.com/{repo}/actions/runs/{os.environ['RUN_ID']}/job/9"})
    out({"check_runs": listed + api}, jq)
log("UNEXPECTED " + endpoint)
sys.stderr.write(f"unexpected gh call: {method} {endpoint}\n"); sys.exit(3)
PY
chmod +x "$T/bin/gh"

HEAD="1111111111111111111111111111111111111111"
CTX="Codex P1 unresolved threads"
EVENT_SEQ=0

# answer <rc> <missing JSON array>: what feedback accounting reports next.
answer_json() {  # <missing JSON array>
  jq -nc --argjson missing "$1" '{
    status: (if ($missing | length) > 0 then "unaccounted" else "clear" end),
    repo: "acme/widget", pr_number: 41,
    feedback_policy: {mode: "by-priority", priorities: {p0: "required", p1: "required",
      p2: "discretionary", p3: "discretionary", nitpick: "discretionary"}},
    posted: ($missing | length), accounted: 0, missing_count: ($missing | length),
    findings: $missing, missing: $missing }'
}
answer() {  # <rc> <missing JSON array>
  { echo "$1"; answer_json "$2"; } >"$T/state/accounting"
}
P2='[{"kind":"inline","reviewer":"chatgpt-codex-connector[bot]","tier":"p2","finding_id":77,"path":"a.sh","line":3,"accounted":false}]'
MINOR='[{"kind":"inline","reviewer":"coderabbitai[bot]","tier":"p2","finding_id":78,"path":"b.sh","line":9,"accounted":false}]'
P1_P2='[{"kind":"inline","reviewer":"chatgpt-codex-connector[bot]","tier":"p2","finding_id":77,"accounted":false},{"kind":"inline","reviewer":"chatgpt-codex-connector[bot]","tier":"p1","finding_id":79,"accounted":false}]'
UNKNOWN='[{"kind":"inline","reviewer":"chatgpt-codex-connector[bot]","tier":"P-unknown","finding_id":80,"accounted":false}]'
P1_THREAD_ON_HEAD=$(jq -nc --arg sha "$HEAD" '[{id: 1001, user: {login: "chatgpt-codex-connector[bot]"},
  body: "![P1 Badge](u) Real blocker.", path: "c.sh", line: 5, commit_id: $sha, original_commit_id: $sha}]')

fresh() {
  rm -rf "$T/state"; mkdir -p "$T/state"
  : >"$T/state/calls"; : >"$T/state/gates"; : >"$T/state/natives"
  answer 0 '[]'
  EVENT_SEQ=0
}

# event [VAR=value ...]: one event-driven job run. Opens its Checks-API lease
# (the step before, which this test does not exercise), runs the extracted
# close step, and records the job-native conclusion its exit code produces.
event() {
  local id rc=0
  EVENT_SEQ=$((EVENT_SEQ + 1))
  id=$(cd "$W" && PATH="$T/bin:$PATH" STATE="$T/state" PR_HEAD="$HEAD" REPO=acme/widget \
    gh api -X POST repos/acme/widget/check-runs -f name="$CTX" -f head_sha="$HEAD" \
    -f status=in_progress --jq .id)
  (
    cd "$W"
    # shellcheck disable=SC1091
    . "$T/close.sh.env"
    export PATH="$T/bin:$PATH" STATE="$T/state" PR_HEAD="$HEAD" REPO=acme/widget
    export GITHUB_OUTPUT="$T/state/output" RUNNER_TEMP="$T/state" GH_TOKEN=installation-token
    export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$T/accounting.sh"
    export ARCHIVE_RESULT=success GATE_READY=true FINGERPRINT_AVAILABLE=true LEGACY_BOOTSTRAP=false
    export PR_NUMBER=41 HEAD_SHA="$HEAD" CHECK_ID="$id" RUN_ID=$((9000 + EVENT_SEQ))
    for kv in "$@"; do export "${kv?}"; done
    bash -e "$T/close.sh"
  ) >"$T/out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then echo success >>"$T/state/natives"; else echo failure >>"$T/state/natives"; fi
  return "$rc"
}

# newest: "<status>|<conclusion>" of the newest Checks-API run of the context.
newest() {
  jq -r --arg n "$CTX" '[.[] | select(.name == $n)] | sort_by(.id) | last
    | if . == null then "none" else "\(.status)|\(.conclusion // "-")" end' "$T/state/runs.json"
}
# merge_state: BLOCKED while any suite's latest run of the context blocks —
# the shared Checks-API suite's newest run, or any event run's native run.
merge_state() {
  if [ "$(newest)" != "completed|success" ] || grep -qx failure "$T/state/natives"; then
    echo BLOCKED
  else
    echo CLEAN
  fi
}
failed_natives() { grep -cx failure "$T/state/natives" || true; }

echo "── (a) non-blocking finding awaiting disposition ──"
fresh; answer 1 "$P2"
event && rc=0 || rc=$?
check "(a) Codex P2 awaiting disposition: the native run is non-failing" '[ "$rc" = 0 ]'
check "(a) the Checks-API lineage carries the pending state: the lease closed red" '[ "$(newest)" = "completed|failure" ]'
check "(a) the head stays BLOCKED until the disposition exists" '[ "$(merge_state)" = BLOCKED ]'
check "(a) the job log says why the native run is non-failing" 'grep -q "is PENDING: only non-blocking findings await disposition" "$T/out"'
check "(a) the gate went on to rule out blocking-tier threads (it read inline comments and threads)" \
  'grep -q "^GET repos/acme/widget/pulls/41/comments" "$T/state/calls"'
check "(a) the lease title still names the accounting failure" \
  'jq -r ".[-1].output.title" "$T/state/runs.json" | grep -q "^Review feedback unaccounted"'
# Three more review events while the finding still waits (the #2617 shape).
event || true; event || true; event || true
check "(a) repeated events during the wait leave no failed native run" '[ "$(failed_natives)" = 0 ] && [ "$(merge_state)" = BLOCKED ]'

echo "── (b) the disposition clears the head with no rerun ──"
answer 0 '[]'
event && rc=0 || rc=$?
check "(b) after the disposition the next event passes" '[ "$rc" = 0 ] && [ "$(newest)" = "completed|success" ]'
check "(b) the head is CLEAN with no rerun of any earlier run" '[ "$(merge_state)" = CLEAN ] && [ "$(failed_natives)" = 0 ]'

fresh; answer 1 "$MINOR"
event && rc=0 || rc=$?
check "(a) CodeRabbit Minor awaiting disposition: non-failing native run, red lineage, BLOCKED" \
  '[ "$rc" = 0 ] && [ "$(newest)" = "completed|failure" ] && [ "$(merge_state)" = BLOCKED ]'
answer 0 '[]'; event || true
check "(b) CodeRabbit Minor dispositioned: CLEAN without a rerun" '[ "$(merge_state)" = CLEAN ]'

echo "── control: a blocking-tier window still leaves a failed run ──"
fresh; answer 1 "$P1_P2"
event && rc=0 || rc=$?
answer 0 '[]'; event || true
check "control: a P1 awaiting disposition fails its native run, which stays on the head after the disposition (manual rerun fallback)" \
  '[ "$rc" = 1 ] && [ "$(newest)" = "completed|success" ] && [ "$(merge_state)" = BLOCKED ] && [ "$(failed_natives)" = 1 ]'

echo "── (c) blocking-tier findings keep failing ──"
fresh; answer 1 "$P1_P2"
event && rc=0 || rc=$?
check "(c) a P1 with dispositions also missing: the native run fails, no pending notice" \
  '[ "$rc" = 1 ] && ! grep -q "is PENDING" "$T/out" && [ "$(newest)" = "completed|failure" ]'
fresh; answer 1 "$P2"
event COMMENTS="$P1_THREAD_ON_HEAD" THREADS='[{"resolved":false,"ids":[1001]}]' && rc=0 || rc=$?
check "(c) a P2 awaiting disposition beside an unresolved P1 thread on HEAD: the native run fails" \
  '[ "$rc" = 1 ] && ! grep -q "is PENDING" "$T/out" && [ "$(merge_state)" = BLOCKED ]'
fresh; answer 1 "$P2"
event COMMENTS="$P1_THREAD_ON_HEAD" THREADS='[{"resolved":true,"ids":[1001]}]' && rc=0 || rc=$?
check "(c) the same P1 thread once resolved no longer blocks: pending again" '[ "$rc" = 0 ] && grep -q "is PENDING" "$T/out"'

echo "── (d) unknown tiers and every error keep failing ──"
fresh; answer 1 "$UNKNOWN"
event && rc=0 || rc=$?
check "(d) an unknown tier: the native run fails" '[ "$rc" = 1 ] && ! grep -q "is PENDING" "$T/out"'
fresh; printf '1\nnot json\n' >"$T/state/accounting"
event && rc=0 || rc=$?
check "(d) a malformed accounting answer: the native run fails" '[ "$rc" = 1 ] && ! grep -q "is PENDING" "$T/out"'
fresh; answer 2 "$P2"
event && rc=0 || rc=$?
check "(d) an accounting read/API error (rc 2): the native run fails" '[ "$rc" = 2 ] && [ "$(newest)" = "completed|failure" ]'
fresh; answer 1 "$P2"
event COMMENTS="$P1_THREAD_ON_HEAD" GRAPHQL_FAIL=1 && rc=0 || rc=$?
check "(d) a reviewThreads API error after a non-blocking accounting failure: the native run fails" \
  '[ "$rc" = 2 ] && ! grep -q "is PENDING" "$T/out"'
fresh; answer 1 "$P2"
event COMMENTS_FAIL=1 && rc=0 || rc=$?
check "(d) an inline-comments API error after a non-blocking accounting failure: the native run fails" '[ "$rc" = 2 ]'

echo "── safeguards: exact head, lineage, snapshot, publication ──"
fresh; answer 1 "$P2"
event PR_HEAD=2222222222222222222222222222222222222222 && rc=0 || rc=$?
check "the PR head moved: no pending, the native run fails" '[ "$rc" = 2 ] && ! grep -q "is PENDING" "$T/out"'
fresh; answer 1 "$P2"
event NATIVE_SUITE=2 && rc=0 || rc=$?
check "pending, but the Checks-API runs share this run's suite: the native run fails" \
  '[ "$rc" = 1 ] && grep -q "could not be confirmed to block" "$T/out"'
fresh; answer 1 "$P2"
event LIST_FAIL=1 && rc=0 || rc=$?
check "pending, but the lineage is unreadable: the native run fails" '[ "$rc" = 1 ]'
fresh; answer 1 "$P2"
event ON_HEAD=0 && rc=0 || rc=$?
check "pending on an issue_comment run (native check not on the head): the native run fails" '[ "$rc" = 1 ]'
fresh; answer 1 "$P2"
event PATCH_FAIL=1 && rc=0 || rc=$?
check "pending, but the lease PATCH failed: no pending verdict, the native run fails" \
  '[ "$rc" = 2 ] && ! grep -q "is PENDING" "$T/out"'
# Attempt 1 sees only a P2 (pending) but the surface moves during it; the
# retried attempt sees a P1 too. The drifted attempt's pending must not speak.
fresh
answer_file() { { echo "$1"; answer_json "$2"; } >"$T/state/$3"; }
answer_file 1 "$P2" a1; answer_file 1 "$P1_P2" a2
printf '%s\n' "$T/state/a1" "$T/state/a2" >"$T/state/accounting-seq"
printf '%s\n' s1 s2 s2 s2 s2 s2 >"$T/state/fingerprints"
event && rc=0 || rc=$?
check "a pending verdict from a drifted snapshot attempt never counts" \
  '[ "$rc" = 1 ] && [ "$(grep -c "^accounting" "$T/state/gates")" = 2 ] && ! grep -q "is PENDING" "$T/out"'
# The reverse: a blocking attempt that drifted, then a pending one, is pending.
fresh
answer_file 1 "$P1_P2" a1; answer_file 1 "$P2" a2
printf '%s\n' "$T/state/a1" "$T/state/a2" >"$T/state/accounting-seq"
printf '%s\n' s1 s2 s2 s2 s2 s2 >"$T/state/fingerprints"
event && rc=0 || rc=$?
check "the published (final) attempt decides: pending after a drifted blocking attempt" '[ "$rc" = 0 ] && grep -q "is PENDING" "$T/out"'
# A stale verdict file from an earlier run on the same runner never speaks.
fresh; answer 1 "$P1_P2"; printf 'pending\n' >"$T/state/codex-p1-verdict"
event && rc=0 || rc=$?
check "a stale verdict file left in RUNNER_TEMP is removed before the driver runs" '[ "$rc" = 1 ] && ! grep -q "is PENDING" "$T/out"'

echo
echo "test_codex_p1_pending.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
