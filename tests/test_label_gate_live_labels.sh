#!/usr/bin/env bash
# Regression coverage for the Label Gate's label source (#1339).
#
# The `label-gate` job in .github/workflows/pr-review-policy.yml used to decide
# from context.payload.pull_request.labels — the event's snapshot. A re-run
# replays the ORIGINAL payload, so a run that failed on a since-removed
# blocking label failed identically on every re-run (seen on #1318). The job
# now reads the PR's live labels and fails closed when it cannot.
#
# The script under test is the REAL github-script body, extracted from the
# workflow with yq and executed under node with mocked github/context/core, so
# the test cannot drift from what CI runs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-review-policy.yml"
AGENT_WORKFLOW="$ROOT/.github/workflows/agent-review.yml"
TRUSTED_WORKFLOW="$ROOT/.github/workflows/trusted-pr-policy.yml"

for tool in yq node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "test_label_gate_live_labels: ERROR $tool is required" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/label-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

yq -r '.jobs."label-gate".steps[] | select(.uses // "" | test("^actions/github-script@")) | .with.script' \
  "$WORKFLOW" >"$WORK/script.js"
if [ ! -s "$WORK/script.js" ]; then
  echo "test_label_gate_live_labels: ERROR could not extract the label-gate github-script body" >&2
  exit 1
fi

cat >"$WORK/harness.mjs" <<'NODE'
import { readFileSync } from 'node:fs';

const body = readFileSync(process.argv[2], 'utf8');
const scenario = JSON.parse(process.argv[3]);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

const calls = [];
const failures = [];
const listLabelsOnIssue = function listLabelsOnIssue() {};
const github = {
  rest: { issues: { listLabelsOnIssue } },
  async paginate(method, params) {
    calls.push({ method: method === listLabelsOnIssue ? 'listLabelsOnIssue' : 'other', params });
    if (scenario.readFails) throw new Error('HTTP 502');
    // Serve the live labels as the flattened result of several pages.
    return scenario.livePages.flat().map(name => ({ name }));
  },
};
const pull_request = { number: 42 };
// The payload snapshot must never be the label source: touching it throws.
Object.defineProperty(pull_request, 'labels', {
  get() { throw new Error('read context.payload.pull_request.labels'); },
});
const context = { repo: { owner: 'o', repo: 'r' }, payload: { pull_request } };
const core = { setFailed: msg => failures.push(msg) };
process.env.CLASSIFIER_RESULT = scenario.classifierResult ?? 'success';
process.env.CLASSIFIER_NEEDS_REVIEW = scenario.needsReview ?? 'false';
process.env.CLASSIFIER_CLASSIFICATION = scenario.classification ?? 'under-threshold';

let crashed = null;
try {
  await new AsyncFunction('github', 'context', 'core', body)(github, context, core);
} catch (err) {
  crashed = err.message;
}
process.stdout.write(JSON.stringify({ calls, failures, crashed }));
NODE

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_HEAD40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BASE40=cccccccccccccccccccccccccccccccccccccccc
OTHER_BASE40=dddddddddddddddddddddddddddddddddddddddd

# #1254: label-only deliveries are recovery inputs for the classifier too. A
# workflow-level `if` that excludes them can publish the two older required
# contexts without ever deriving Phase 4 applicability. Label writes made by
# the classifier use GITHUB_TOKEN, so its addition does not recurse; PAT-driven
# removal is handled by the lifecycle guard below, while other label events
# get one fresh classification.
CLASSIFIER_IF=$(yq -r '.jobs."external-review-labeling".if // ""' "$WORKFLOW")
if [[ "$CLASSIFIER_IF" != *"github.event.action != 'labeled'"* ]] \
   && [[ "$CLASSIFIER_IF" != *"github.event.action != 'unlabeled'"* ]]; then
  pass "label events are not excluded from the external-review classifier (#1254)"
else
  fail "external-review classifier still excludes label events: $CLASSIFIER_IF"
fi

# The classifier body itself has no label-event early exit: even the
# needs-external-review lifecycle gets a fresh classification. Only the label
# APPLY step suppresses re-adding a PAT-cleared label (#969).
CLASSIFIER_BODY=$(yq -r '.jobs."external-review-labeling".steps[] | select(.id == "check") | .run' "$WORKFLOW")
APPLY_IF=$(yq -r '.jobs."classify-and-mutate".steps[] | select(.name == "Apply label and comment") | .if' "$TRUSTED_WORKFLOW")
if [[ "$CLASSIFIER_BODY" != *'label_lifecycle_event=true'* ]] \
   && [[ "$APPLY_IF" == *"github.event.action == 'unlabeled'"* ]] \
   && [[ "$APPLY_IF" == *"github.event.label.name == 'needs-external-review'"* ]]; then
  pass "needs-external-review removals are classified without being immediately re-added (#1254/#969)"
else
  fail "label lifecycle classification/apply boundary is missing"
fi

# GitHub compiles any run scalar containing an expression as one format
# expression, which has a 21,000-character registration limit. Keep the large
# classifier body expression-free by moving event values into its step env.
CLASSIFIER_RUN_BYTES=$(printf '%s' "$CLASSIFIER_BODY" | LC_ALL=C wc -c | tr -d ' ')
CLASSIFIER_ENV=$(yq -o=json -I=0 '.jobs."external-review-labeling".steps[] | select(.id == "check") | .env' "$WORKFLOW")
if jq -e '
        .BASE_SHA == "${{ github.event.pull_request.base.sha }}"
        and .HEAD_SHA == "${{ github.event.pull_request.head.sha }}"
        and .HEAD_REF == "${{ github.event.pull_request.head.ref }}"
        and .PR_AUTHOR == "${{ github.event.pull_request.user.login }}"
        and .REPO == "${{ github.repository }}"
        and .DEFAULT_BRANCH == "${{ github.event.repository.default_branch }}"
      ' <<<"$CLASSIFIER_ENV" >/dev/null \
   && { [ "$CLASSIFIER_RUN_BYTES" -le 21000 ] || [[ "$CLASSIFIER_BODY" != *'${{'* ]]; }; then
  pass "oversized classifier body keeps GitHub expressions in step env"
else
  fail "classifier run scalar can exceed GitHub's expression limit (bytes=$CLASSIFIER_RUN_BYTES)"
fi

# #1251: the live read must happen after classification, and a failed or
# skipped classifier must make Label Gate red rather than silently skipping
# the dependent required context.
LABEL_NEEDS=$(yq -r '.jobs."label-gate".needs // ""' "$WORKFLOW")
LABEL_IF=$(yq -r '.jobs."label-gate".if // ""' "$WORKFLOW")
if [ "$LABEL_NEEDS" = "external-review-labeling" ] && [ "$LABEL_IF" = "always()" ]; then
  pass "Label Gate waits for the classifier and still runs after non-success (#1251)"
else
  fail "Label Gate ordering contract missing (needs=$LABEL_NEEDS if=$LABEL_IF)"
fi
run() { node "$WORK/harness.mjs" "$WORK/script.js" "$1"; }

# <label> <scenario-json> <jq assertion over the harness result>
check() {
  local label=$1 scenario=$2 assertion=$3 out
  out=$(run "$scenario") || { fail "$label: harness exited non-zero"; return; }
  if printf '%s' "$out" | jq -e "$assertion" >/dev/null; then
    pass "$label"
  else
    fail "$label: $out"
  fi
}

# 1. The #1318 case: the label is gone from the PR. A re-run must now PASS,
#    whatever the replayed payload says — the harness makes reading the
#    payload's labels throw, so a pass here proves they were not consulted.
check "a removed blocking label no longer fails the gate (re-run can retire a stale failure)" \
  '{"livePages":[[]]}' \
  '.crashed == null and .failures == []'

check "an absent label cannot clear a review-required classifier before trusted mutation arrives" \
  '{"livePages":[[]],"needsReview":"true","classification":"external-required"}' \
  '.crashed == null and (.failures | length) == 1'
check "a stale classifier fails closed even after label removal" \
  '{"livePages":[[]],"classification":"stale-event"}' \
  '.crashed == null and (.failures | length) == 1'
check "a late trusted label still blocks an otherwise cleared classifier" \
  '{"livePages":[["needs-external-review"]],"classification":"external-cleared"}' \
  '.crashed == null and (.failures | length) == 1'

# 2. A blocking label present NOW fails, named in the message.
check "a live blocking label fails the gate" \
  '{"livePages":[["bug","human-hold"]]}' \
  '.crashed == null and (.failures | length) == 1 and (.failures[0] | test("human-hold"))'

# 3. Every blocking label is named, and unrelated ones are not.
check "all live blocking labels are reported, unrelated labels ignored" \
  '{"livePages":[["needs-external-review","enhancement","policy-violation"]]}' \
  '(.failures[0] | test("needs-external-review") and test("policy-violation") and (test("enhancement") | not))'

# 4. Pagination: a blocker on a later page is still seen.
check "a blocking label beyond the first page is seen" \
  '{"livePages":[["a","b","c"],["needs-human-review"]]}' \
  '(.failures | length) == 1 and (.failures[0] | test("needs-human-review"))'

# 5. FAIL CLOSED: an unreadable label set is not a clear one.
check "a failed live read fails closed" \
  '{"readFails":true,"livePages":[[]]}' \
  '.crashed == null and (.failures | length) == 1 and (.failures[0] | test("Could not read the current labels"))'

# 6. A failed/skipped classifier cannot turn into a green or skipped Label
#    Gate. It fails before the label read because that read cannot repair an
#    unknown classification result.
check "a failed classifier fails Label Gate closed without reading labels" \
  '{"classifierResult":"failure","livePages":[[]]}' \
  '.crashed == null and .calls == [] and (.failures | length) == 1 and (.failures[0] | test("finished with failure"))'

check "a skipped classifier fails Label Gate closed without reading labels" \
  '{"classifierResult":"skipped","livePages":[[]]}' \
  '.crashed == null and .calls == [] and (.failures | length) == 1 and (.failures[0] | test("finished with skipped"))'

# 8. The read targets this PR's issue, paginated, through listLabelsOnIssue.
check "the read is listLabelsOnIssue for this PR, paginated" \
  '{"livePages":[[]]}' \
  '.calls == [{"method":"listLabelsOnIssue","params":{"owner":"o","repo":"r","issue_number":42,"per_page":100}}]'

# 9. No unrelated labels, no failure.
check "unrelated labels alone pass" \
  '{"livePages":[["documentation","enhancement"]]}' \
  '.crashed == null and .failures == []'

# The independent triage path delegates authority to the live byte verifier.
# Execute the actual workflow block and verify its exact pair/policy inputs,
# fail-closed outcomes, and independence from historical comment markers.
yq -r '.jobs.triage.steps[] | select(.id == "check") | .with.script' \
  "$AGENT_WORKFLOW" >"$WORK/agent-triage.js"
awk '
  /let laneVerifiedHead = false;/ { capture=1 }
  capture && /\/\/ Export intrinsic threshold\/path requiredness/ { exit }
  capture { print }
' "$WORK/agent-triage.js" >"$WORK/agent-lane-reader.js"
if [ ! -s "$WORK/agent-lane-reader.js" ]; then
  fail "could not extract agent-review's live propagation verifier"
else
  cat >>"$WORK/agent-lane-reader.js" <<'NODE'
return laneVerifiedHead;
NODE
fi

cat >"$WORK/agent-lane-harness.mjs" <<'NODE'
import { readFileSync } from 'node:fs';

const body = readFileSync(process.argv[2], 'utf8');
const scenario = JSON.parse(process.argv[3]);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const warnings = [];
const calls = [];
const github = {
  rest: { issues: { listComments() {} } },
  async paginate(_method, params) {
    calls.push(params);
    if (scenario.readFails) throw new Error('HTTP 502');
    return scenario.comments;
  },
};
const context = { repo: { owner: 'o', repo: 'r' } };
const core = { warning: message => warnings.push(message) };
const needsExternal = true;
const policyReadFailed = Boolean(scenario.policyReadFailed);
const policyConfigPath = '/trusted/governing-policy.yml';
async function execFileAsync(file, args, options) {
  calls.push({file, args, options});
  if (scenario.verifierFails) throw new Error('live byte verification refused');
  return '';
}
const pr = {
  number: 42,
  head: { ref: 'mergepath-sync/deadbee', sha: scenario.head },
  base: { sha: scenario.base },
};
let crashed = null;
let laneVerifiedHead = null;
try {
  laneVerifiedHead = await new AsyncFunction(
    'github', 'context', 'core', 'needsExternal', 'pr',
    'execFileAsync', 'policyReadFailed', 'policyConfigPath', body
  )(github, context, core, needsExternal, pr,
    execFileAsync, policyReadFailed, policyConfigPath);
} catch (err) {
  crashed = err.message;
}
process.stdout.write(JSON.stringify({ laneVerifiedHead, warnings, calls, crashed }));
NODE

agent_lane_check() { # <label> <scenario-json> <jq-assertion>
  local label=$1 scenario=$2 assertion=$3 out
  out=$(node "$WORK/agent-lane-harness.mjs" "$WORK/agent-lane-reader.js" "$scenario") \
    || { fail "$label: harness exited non-zero"; return; }
  if jq -e "$assertion" >/dev/null <<<"$out"; then
    pass "$label"
  else
    fail "$label: $out"
  fi
}

agent_lane_check "agent triage delegates the exact live pair and governing policy" \
  "$(jq -nc --arg h "$HEAD40" --arg b "$BASE40" '{head:$h,base:$b,comments:[]}')" \
  '.crashed == null and .laneVerifiedHead == true and (.calls | length) == 1
   and .calls[0].file == "bash"
   and .calls[0].args == ["scripts/workflow/verify-live-propagation.sh", "o/r", "42", "'"$HEAD40"'", "'"$BASE40"'", "/trusted/governing-policy.yml"]'

agent_lane_check "agent triage supplies the live PR snapshot and bounded verifier options" \
  "$(jq -nc --arg h "$HEAD40" --arg b "$BASE40" '{head:$h,base:$b,comments:[]}')" \
  '.crashed == null and .calls[0].options.encoding == "utf8"
   and .calls[0].options.timeout == 120000
   and (.calls[0].options.input | fromjson) == {number:42,head:{ref:"mergepath-sync/deadbee",sha:"'"$HEAD40"'"},base:{sha:"'"$BASE40"'"}}'

agent_lane_check "agent triage keeps a rejected live pair external-required" \
  "$(jq -nc --arg h "$HEAD40" --arg b "$OTHER_BASE40" '{head:$h,base:$b,comments:[],verifierFails:true}')" \
  '.crashed == null and .laneVerifiedHead == false and (.calls | length) == 1 and (.warnings | length) == 1'

agent_lane_check "agent triage does not accept a legacy marker after verification fails" \
  "$(jq -nc --arg h "$HEAD40" --arg b "$BASE40" '{head:$h,base:$b,verifierFails:true,comments:[{user:{login:"github-actions[bot]"},body:("<!-- mergepath-propagation-lane verified-head="+$h+" -->")}]}')" \
  '.crashed == null and .laneVerifiedHead == false and (.calls | length) == 1'

agent_lane_check "agent triage does not accept a spoofable bot marker after verification fails" \
  "$(jq -nc --arg h "$HEAD40" --arg b "$BASE40" '{head:$h,base:$b,verifierFails:true,comments:[{user:{login:"github-actions[bot]"},body:("<!-- mergepath-propagation-lane:v2 verified-head="+$h+" verified-base="+$b+" -->")}]}')" \
  '.crashed == null and .laneVerifiedHead == false and (.calls | length) == 1'

agent_lane_check "agent triage skips propagation exemption when the governing policy is unreadable" \
  "$(jq -nc --arg h "$HEAD40" --arg b "$BASE40" '{head:$h,base:$b,comments:[],policyReadFailed:true}')" \
  '.crashed == null and .laneVerifiedHead == false and .calls == []'

# #1321: execute the real reconciliation step with a fake public API. The stub
# accepts only paginated timeline/comment reads, so the positive case also
# proves that ownership is decided over the complete surfaces.
yq -r '.jobs."classify-and-mutate".steps[] | select(.name == "Reconcile a policy-owned fail-closed label") | .run' \
  "$TRUSTED_WORKFLOW" >"$WORK/reconcile.sh"
if [ ! -s "$WORK/reconcile.sh" ]; then
  fail "could not extract the fail-closed label reconciliation step"
else
  pass "fail-closed label reconciliation step is present"
fi

yq -r '.jobs."classify-and-mutate".steps[] | select(.name == "Apply label and comment") | .run' \
  "$TRUSTED_WORKFLOW" | sed 's|${{ github.repository }}|o/r|g' >"$WORK/apply.sh"
if [ ! -s "$WORK/apply.sh" ]; then
  fail "could not extract the label application step"
else
  pass "label application step is present"
fi

yq -r '.jobs."classify-and-mutate".steps[] | select(.name == "Propagation PR review lane") | .run' \
  "$TRUSTED_WORKFLOW" | sed 's|${{ github.repository }}|o/r|g' >"$WORK/propagation.sh"
if [ ! -s "$WORK/propagation.sh" ]; then
  fail "could not extract the propagation review lane"
else
  pass "propagation review lane is present"
fi

mkdir -p "$WORK/bin"
REAL_BASH=$(command -v bash)
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls"
case "$*" in
  "api --paginate repos/o/r/pulls/42/files")
    printf '[{"filename":"src/example.sh","status":"modified","additions":400,"deletions":0}]\n' ;;
  "pr view 42 --repo o/r --json labels --jq .labels[].name")
    cat "$GH_STUB_DIR/labels.txt" ;;
  "pr view 42 --repo o/r --json comments --jq .comments[].body"|\
  "api --paginate repos/o/r/issues/42/comments --jq .[].body")
    cat "$GH_STUB_DIR/pr-comments.txt" ;;
  "api repos/o/r/pulls/42 --jq {head:.head.sha,base:.base.sha}")
    [ ! -f "$GH_STUB_DIR/fail-live-head" ] || exit 1
    count=$(cat "$GH_STUB_DIR/pair-count" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" >"$GH_STUB_DIR/pair-count"
    if [ "$count" -gt 1 ] && [ -f "$GH_STUB_DIR/live-pair-2" ]; then
      cat "$GH_STUB_DIR/live-pair-2"
    else
      cat "$GH_STUB_DIR/live-pair"
    fi ;;
  "pr edit 42 --add-label needs-external-review --repo o/r")
    printf 'added\n' >>"$GH_STUB_DIR/label-writes" ;;
  "pr edit 42 --remove-label needs-external-review --repo o/r")
    printf 'removed\n' >>"$GH_STUB_DIR/label-removals" ;;
  "pr comment 42 --repo o/r --body "*)
    printf '%s' "${7-}" >>"$GH_STUB_DIR/comment-writes" ;;
  "api -X POST repos/o/r/dispatches "*)
    printf 'dispatched\n' >>"$GH_STUB_DIR/dispatches" ;;
  "api --paginate repos/o/r/issues/42/timeline")
    [ ! -f "$GH_STUB_DIR/fail-timeline" ] || exit 1
    cat "$GH_STUB_DIR/timeline.json" ;;
  "api --paginate repos/o/r/issues/42/comments")
    cat "$GH_STUB_DIR/comments.json" ;;
  "api repos/o/r/pulls/42")
    count=$(cat "$GH_STUB_DIR/live-count" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" >"$GH_STUB_DIR/live-count"
    if [ "$count" -gt 1 ] && [ -f "$GH_STUB_DIR/live-2.json" ]; then
      cat "$GH_STUB_DIR/live-2.json"
    else
      cat "$GH_STUB_DIR/live.json"
    fi ;;
  "api -X DELETE repos/o/r/issues/42/labels/needs-external-review")
    [ ! -f "$GH_STUB_DIR/fail-delete" ] || exit 1
    printf 'deleted\n' >>"$GH_STUB_DIR/deletes"
    printf '{}\n' ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 90 ;;
esac
SH
chmod +x "$WORK/bin/gh"

# Execute the real classifier shell body for the carry-forward boundary. The
# workflow still materializes its trusted base tree and selects the trusted
# helpers; only those helpers' responses and GitHub's files endpoint are
# replaced, so duplicate or contradictory GITHUB_OUTPUT writes remain visible.
cat >"$WORK/bin/bash" <<'SH'
#!/bin/bash
set -euo pipefail
case "${1-}" in
  */scripts/codex-review-check.sh)
    printf 'args=%s\nskip_ci=%s\nrequire_head=%s\nconfig=%s\n' \
      "$*" "${CODEX_REVIEW_CHECK_SKIP_CI-}" \
      "${CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD-}" \
      "${MERGEPATH_REVIEW_POLICY_PATH-}" >"$GH_STUB_DIR/clearance-call"
    exit "${CLEARANCE_RC:-1}" ;;
  */external_review_fingerprint.sh)
    [ "${FINGERPRINT_RC:-0}" -eq 0 ] || exit "$FINGERPRINT_RC"
    printf '%s\n' "${FINGERPRINT_JSON:?}" ;;
  */external_review_carryforward.sh)
    [ "${CARRY_RC:-0}" -eq 0 ] || exit "$CARRY_RC"
    printf '%s\n' "${CARRY_JSON:?}" ;;
  */dependabot_pin_bump_exemption.sh)
    # The Dependabot action-pin bump lane helper (#2164): record the exact
    # invocation so the suite can prove the trusted-tree path and the pinned
    # pair, then answer with the scripted verdict.
    printf '%s\n' "$*" >"$GH_STUB_DIR/pin-call"
    printf '%s\n' "${PIN_JSON-}"
    exit "${PIN_RC:-1}" ;;
  *) exec "$REAL_BASH" "$@" ;;
esac
SH
chmod +x "$WORK/bin/bash"

write_apply_fixture() { # <dir> <live-head> [labels] [live-base]
  local dir=$1 live_head=$2 labels=${3-} live_base=${4:-$BASE40}
  mkdir -p "$dir"
  jq -n --arg head "$live_head" --arg base "$live_base" '{head:$head,base:$base}' \
    >"$dir/live-pair"
  printf '%s\n' "$labels" >"$dir/labels.txt"
}

run_apply() { # <fixture-dir> [classification] [reasons]
  local dir=$1 classification=${2:-fail-closed}
  local reasons=${3:-- Could not read policy; requiring review fail-closed} rc=0
  env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" GH_STUB_DIR="$dir" \
    PR_NUMBER=42 HEAD_SHA="$HEAD40" BASE_SHA="$BASE40" CLASSIFICATION="$classification" \
    REASONS="$reasons" \
    "$REAL_BASH" "$WORK/apply.sh" >"$dir/out" 2>"$dir/err" || rc=$?
  printf '%s' "$rc"
}

A1="$WORK/apply-current-head"
write_apply_fixture "$A1" "$HEAD40"
rc=$(run_apply "$A1")
if [ "$rc" -eq 0 ] && [ "$(cat "$A1/label-writes" 2>/dev/null)" = added ] \
   && grep -Fq "mergepath-external-review-label:v1 head=$HEAD40 cause=fail-closed" "$A1/comment-writes"; then
  pass "current-head classification applies the label and matching provenance comment"
else
  fail "current-head classification did not publish both writes (rc=$rc out=$(cat "$A1/out") err=$(cat "$A1/err"))"
fi

A2="$WORK/apply-stale-head"
write_apply_fixture "$A2" "$OTHER_HEAD40"
rc=$(run_apply "$A2")
if [ "$rc" -eq 0 ] && [ ! -f "$A2/label-writes" ] && [ ! -f "$A2/comment-writes" ]; then
  pass "stale event head skips label and comment writes successfully"
else
  fail "stale event head wrote or failed unexpectedly (rc=$rc out=$(cat "$A2/out") err=$(cat "$A2/err"))"
fi

A3="$WORK/apply-head-read-failure"
write_apply_fixture "$A3" "$HEAD40"
touch "$A3/fail-live-head"
rc=$(run_apply "$A3")
if [ "$rc" -ne 0 ] && [ ! -f "$A3/label-writes" ] && [ ! -f "$A3/comment-writes" ]; then
  pass "unreadable live head fails closed without label or comment writes"
else
  fail "unreadable live head did not fail closed (rc=$rc out=$(cat "$A3/out") err=$(cat "$A3/err"))"
fi

A4="$WORK/apply-malformed-head"
write_apply_fixture "$A4" not-a-sha
rc=$(run_apply "$A4")
if [ "$rc" -ne 0 ] && [ ! -f "$A4/label-writes" ] && [ ! -f "$A4/comment-writes" ]; then
  pass "malformed live head fails closed without label or comment writes"
else
  fail "malformed live head did not fail closed (rc=$rc out=$(cat "$A4/out") err=$(cat "$A4/err"))"
fi

A5="$WORK/apply-existing-label"
write_apply_fixture "$A5" "$HEAD40" needs-external-review
rc=$(run_apply "$A5")
if [ "$rc" -eq 0 ] && [ ! -f "$A5/label-writes" ] && [ ! -f "$A5/comment-writes" ]; then
  pass "an existing label still suppresses duplicate writes"
else
  fail "existing label produced duplicate writes (rc=$rc out=$(cat "$A5/out") err=$(cat "$A5/err"))"
fi

A5B="$WORK/apply-stale-base"
write_apply_fixture "$A5B" "$HEAD40" '' "$OTHER_BASE40"
rc=$(run_apply "$A5B")
if [ "$rc" -eq 0 ] && [ ! -f "$A5B/label-writes" ] && [ ! -f "$A5B/comment-writes" ]; then
  pass "a same-head retarget skips stale label and comment writes successfully"
else
  fail "stale event base wrote or failed unexpectedly (rc=$rc out=$(cat "$A5B/out") err=$(cat "$A5B/err"))"
fi

A5C="$WORK/apply-malformed-base"
write_apply_fixture "$A5C" "$HEAD40" '' not-a-sha
rc=$(run_apply "$A5C")
if [ "$rc" -ne 0 ] && [ ! -f "$A5C/label-writes" ] && [ ! -f "$A5C/comment-writes" ]; then
  pass "a malformed live base fails closed without label or comment writes"
else
  fail "malformed live base did not fail closed (rc=$rc out=$(cat "$A5C/out") err=$(cat "$A5C/err"))"
fi

write_propagation_fixture() { # <dir> <live-head> [live-base]
  local dir=$1 live_head=$2 live_base=${3:-$BASE40}
  mkdir -p "$dir"
  jq -n --arg head "$live_head" --arg base "$live_base" '{head:$head,base:$base}' \
    >"$dir/live-pair"
  printf '%s\n' needs-external-review >"$dir/labels.txt"
  : >"$dir/pr-comments.txt"
}

run_propagation() { # <fixture-dir>
  local dir=$1 rc=0
  env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" GH_STUB_DIR="$dir" \
    GH_TOKEN=fake-read LABEL_REMOVAL_TOKEN=fake-write PR_NUMBER=42 \
    HEAD_SHA="$HEAD40" BASE_SHA="$BASE40" \
    "$REAL_BASH" --noprofile --norc -e -o pipefail "$WORK/propagation.sh" \
      >"$dir/out" 2>"$dir/err" || rc=$?
  printf '%s' "$rc"
}

P1="$WORK/propagation-current-pair"
write_propagation_fixture "$P1" "$HEAD40"
rc=$(run_propagation "$P1")
if [ "$rc" -eq 0 ] \
   && [ -s "$P1/comment-writes" ] \
   && grep -Fq "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" "$P1/comment-writes" \
   && [ "$(cat "$P1/dispatches" 2>/dev/null)" = dispatched ] \
   && [ "$(cat "$P1/label-removals" 2>/dev/null)" = removed ]; then
  pass "verified propagation publishes authority and removes the label only on the event head/base"
else
  fail "current propagation head/base did not publish and remove as expected (rc=$rc out=$(cat "$P1/out") err=$(cat "$P1/err"))"
fi

P1B="$WORK/propagation-legacy-marker"
write_propagation_fixture "$P1B" "$HEAD40"
printf '%s\n' "<!-- mergepath-propagation-lane verified-head=$HEAD40 -->" >"$P1B/pr-comments.txt"
rc=$(run_propagation "$P1B")
if [ "$rc" -eq 0 ] \
   && grep -Fq "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" "$P1B/comment-writes" \
   && [ "$(cat "$P1B/dispatches" 2>/dev/null)" = dispatched ]; then
  pass "a legacy head-only marker does not suppress v2 pair authority"
else
  fail "legacy marker suppressed the v2 pair marker (rc=$rc out=$(cat "$P1B/out") err=$(cat "$P1B/err"))"
fi

P1C="$WORK/propagation-other-base-marker"
write_propagation_fixture "$P1C" "$HEAD40"
printf '%s\n' "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$OTHER_BASE40 -->" >"$P1C/pr-comments.txt"
rc=$(run_propagation "$P1C")
if [ "$rc" -eq 0 ] \
   && grep -Fq "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" "$P1C/comment-writes" \
   && [ "$(cat "$P1C/dispatches" 2>/dev/null)" = dispatched ]; then
  pass "a same-head marker for another base does not suppress current-pair authority"
else
  fail "wrong-base marker suppressed current-pair authority (rc=$rc out=$(cat "$P1C/out") err=$(cat "$P1C/err"))"
fi

P1D="$WORK/propagation-existing-pair-marker"
write_propagation_fixture "$P1D" "$HEAD40"
printf '%s\n' "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" >"$P1D/pr-comments.txt"
rc=$(run_propagation "$P1D")
if [ "$rc" -eq 0 ] && [ ! -f "$P1D/comment-writes" ] \
   && [ ! -f "$P1D/dispatches" ] \
   && [ "$(cat "$P1D/label-removals" 2>/dev/null)" = removed ]; then
  pass "an existing current-pair v2 marker deduplicates authority publication"
else
  fail "current-pair marker did not deduplicate publication (rc=$rc out=$(cat "$P1D/out") err=$(cat "$P1D/err"))"
fi

P2="$WORK/propagation-stale-head"
write_propagation_fixture "$P2" "$OTHER_HEAD40"
rc=$(run_propagation "$P2")
if [ "$rc" -eq 0 ] && [ ! -f "$P2/comment-writes" ] \
   && [ ! -f "$P2/dispatches" ] && [ ! -f "$P2/label-removals" ]; then
  pass "a delayed propagation run publishes no authority and preserves a newer head's label"
else
  fail "stale propagation head published authority, removed the label, or failed unexpectedly (rc=$rc out=$(cat "$P2/out") err=$(cat "$P2/err"))"
fi

P3="$WORK/propagation-stale-base"
write_propagation_fixture "$P3" "$HEAD40" "$OTHER_BASE40"
rc=$(run_propagation "$P3")
if [ "$rc" -eq 0 ] && [ ! -f "$P3/comment-writes" ] \
   && [ ! -f "$P3/dispatches" ] && [ ! -f "$P3/label-removals" ]; then
  pass "a delayed propagation run publishes no authority after a base retarget"
else
  fail "stale propagation base published authority, removed the label, or failed unexpectedly (rc=$rc out=$(cat "$P3/out") err=$(cat "$P3/err"))"
fi

P3B="$WORK/propagation-stale-base-no-label"
write_propagation_fixture "$P3B" "$HEAD40" "$OTHER_BASE40"
: >"$P3B/labels.txt"
rc=$(run_propagation "$P3B")
if [ "$rc" -eq 0 ] && [ ! -f "$P3B/comment-writes" ] \
   && [ ! -f "$P3B/dispatches" ] && [ ! -f "$P3B/label-removals" ]; then
  pass "a stale same-head retarget publishes no authority even when no label is present"
else
  fail "label absence let a stale retarget publish propagation authority (rc=$rc out=$(cat "$P3B/out") err=$(cat "$P3B/err"))"
fi

P4="$WORK/propagation-pair-read-failure"
write_propagation_fixture "$P4" "$HEAD40"
touch "$P4/fail-live-head"
rc=$(run_propagation "$P4")
if [ "$rc" -ne 0 ] && [ ! -f "$P4/comment-writes" ] \
   && [ ! -f "$P4/dispatches" ] && [ ! -f "$P4/label-removals" ]; then
  pass "an unreadable live pair fails propagation authority publication closed"
else
  fail "unreadable propagation pair did not fail closed (rc=$rc out=$(cat "$P4/out") err=$(cat "$P4/err"))"
fi

P5="$WORK/propagation-malformed-pair"
write_propagation_fixture "$P5" not-a-sha
rc=$(run_propagation "$P5")
if [ "$rc" -ne 0 ] && [ ! -f "$P5/comment-writes" ] \
   && [ ! -f "$P5/dispatches" ] && [ ! -f "$P5/label-removals" ]; then
  pass "a malformed live pair fails propagation authority publication closed"
else
  fail "malformed propagation pair did not fail closed (rc=$rc out=$(cat "$P5/out") err=$(cat "$P5/err"))"
fi

P6="$WORK/propagation-moves-after-marker"
write_propagation_fixture "$P6" "$HEAD40"
jq -n --arg head "$HEAD40" --arg base "$OTHER_BASE40" '{head:$head,base:$base}' \
  >"$P6/live-pair-2"
rc=$(run_propagation "$P6")
if [ "$rc" -eq 0 ] \
   && [ -s "$P6/comment-writes" ] \
   && [ "$(cat "$P6/dispatches" 2>/dev/null)" = dispatched ] \
   && [ ! -f "$P6/label-removals" ]; then
  pass "movement after marker publication is caught by the pre-delete fence"
else
  fail "post-marker movement bypassed the pre-delete fence (rc=$rc out=$(cat "$P6/out") err=$(cat "$P6/err"))"
fi

# The classifier materializes trusted base trees with git worktree, so give it
# a tiny self-contained repository instead of borrowing the test caller's
# history. This deliberately has exactly the base and head commits the event
# needs: the suite can therefore run from a depth-1 Actions checkout too.
CLASSIFIER_REPO="$WORK/classifier-repo"
mkdir -p "$CLASSIFIER_REPO/.github" "$CLASSIFIER_REPO/scripts/workflow" "$CLASSIFIER_REPO/src"
# Match the classifier's $PWD spelling when TMPDIR has a trailing separator.
CLASSIFIER_REPO="$(cd "$CLASSIFIER_REPO" && pwd)"
git -C "$CLASSIFIER_REPO" init --quiet -b main
git -C "$CLASSIFIER_REPO" config user.name "NathanPayne"
git -C "$CLASSIFIER_REPO" config user.email "github@nathanpayne.com"
printf '%s\n' 'external_review_threshold: 100' >"$CLASSIFIER_REPO/.github/review-policy.yml"
for helper in \
  scripts/workflow/external_review_fingerprint.sh \
  scripts/workflow/external_review_carryforward.sh \
  scripts/workflow/dependabot_pin_bump_exemption.sh \
  scripts/codex-review-check.sh; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' >"$CLASSIFIER_REPO/$helper"
  chmod +x "$CLASSIFIER_REPO/$helper"
done
printf '%s\n' 'base' >"$CLASSIFIER_REPO/src/example.sh"
git -C "$CLASSIFIER_REPO" add .
git -C "$CLASSIFIER_REPO" commit --quiet -m 'fixture base'
EVENT_BASE=$(git -C "$CLASSIFIER_REPO" rev-parse HEAD)
printf '%s\n' 'head' >"$CLASSIFIER_REPO/src/example.sh"
git -C "$CLASSIFIER_REPO" add src/example.sh
git -C "$CLASSIFIER_REPO" commit --quiet -m 'fixture head'
EVENT_HEAD=$(git -C "$CLASSIFIER_REPO" rev-parse HEAD)
# The production classifier fetches candidate objects as inert data.
git -C "$CLASSIFIER_REPO" remote add origin "$CLASSIFIER_REPO"
git -C "$CLASSIFIER_REPO" update-ref refs/pull/42/head "$EVENT_HEAD"

yq -r '.jobs."external-review-labeling".steps[] | select(.id == "check") | .run' \
  "$WORKFLOW" >"$WORK/classifier.sh"

REAL_GIT=$(command -v git)
cat >"$WORK/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -euo pipefail
original=("$@")
flags=""
while [ "${1-}" = -c ]; do flags="$flags $2"; shift 2; done
case "$*" in
  'config --local --get remote.origin.url')
    [ "${FIXTURE_REMOTE_URL-}" != missing ] || exit 1
    printf '%s\n' "${FIXTURE_REMOTE_URL:?}" ;;
  'config --local --get-regexp '*)
    [ "${FIXTURE_REWRITE:-0}" = 1 ] && { printf 'url.https://evil.invalid/.insteadof https://github.com/\n'; exit 0; }
    exit 1 ;;
  'fetch --no-tags '*)
    [ "$3" = 'https://github.com/o/r.git' ] || exit 91
    [ "${GIT_TERMINAL_PROMPT-}" = 0 ] && [ "${GIT_CONFIG_GLOBAL-}" = /dev/null ] && [ "${GIT_CONFIG_NOSYSTEM-}" = 1 ] || exit 92
    for flag in core.hooksPath=/dev/null core.fsmonitor=false credential.helper= credential.useHttpPath=true http.followRedirects=false protocol.allow=never protocol.https.allow=always; do
      [[ "$flags" == *" $flag"* ]] || exit 93
    done
    [ -x "${GIT_ASKPASS:-}" ] && [ "$HOME/askpass" = "$GIT_ASKPASS" ] || exit 94
    printf '%s\n' "$GIT_ASKPASS" >>"$GH_STUB_DIR/askpass-paths"
    [ "$("$GIT_ASKPASS" "Username for 'https://github.com/o/r.git': ")" = x-access-token ] || exit 95
    [ "$("$GIT_ASKPASS" "Password for 'https://x-access-token@github.com/o/r.git': ")" = fake-classifier-read ] || exit 96
    if "$GIT_ASKPASS" "Password for 'https://evil.invalid/o/r.git': " >/dev/null; then exit 97; fi
    ! grep -Fq fake-classifier-read "$GIT_ASKPASS" || exit 98
    [[ "$*" != *fake-classifier-read* ]] || exit 99
    # Exercise Git's real credential prompt protocol without HTTP/network.
    # The clean fake HOME and reset helper list prevent ambient credentials.
    filled=$(printf 'protocol=https\nhost=github.com\npath=o/r.git\n\n' | "$REAL_GIT" -c credential.helper= -c credential.useHttpPath=true credential fill)
    [[ "$filled" == *'username=x-access-token'* && "$filled" == *'password=fake-classifier-read'* ]] || exit 101
    printf 'verified-private-fetch\n' >>"$GH_STUB_DIR/fetches"
    [ "${FIXTURE_FETCH_FAIL:-0}" != 1 ] || exit 100
    # No network: after checking the real production fetch/askpass contract,
    # map the verified URL to this suite's inert local Git-object fixture.
    exec "$REAL_GIT" -c core.hooksPath=/dev/null -c protocol.file.allow=always fetch --no-tags "$CLASSIFIER_REPO" "$4" ;;
  *) exec "$REAL_GIT" "${original[@]}" ;;
esac
GIT_STUB
chmod +x "$WORK/bin/git"

run_classifier() { # <fixture-dir> <fingerprint-rc> <carry-rc> <carry-json> [clearance-rc]
  local dir=$1 fingerprint_rc=$2 carry_rc=$3 carry_json=$4 clearance_rc=${5:-1} rc=0
  mkdir -p "$dir"
  if [ ! -f "$dir/live-pair" ]; then
    jq -n --arg head "$EVENT_HEAD" --arg base "$EVENT_BASE" '{head:$head,base:$base}' \
      >"$dir/live-pair"
  fi
  (
    cd "$CLASSIFIER_REPO"
    env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" REAL_GIT="$REAL_GIT" CLASSIFIER_REPO="$CLASSIFIER_REPO" GH_STUB_DIR="$dir" \
      GH_TOKEN="${CLASSIFIER_TOKEN_OVERRIDE-fake-classifier-read}" \
      FIXTURE_REMOTE_URL="${FETCH_ORIGIN_OVERRIDE-https://github.com/o/r}" \
      FIXTURE_REWRITE="${FETCH_REWRITE_OVERRIDE:-0}" FIXTURE_FETCH_FAIL="${FETCH_FAIL_OVERRIDE:-0}" \
      GITHUB_OUTPUT="$dir/output" PR_NUMBER=42 EVENT_ACTION="${EVENT_ACTION_OVERRIDE:-labeled}" \
      BASE_SHA="$EVENT_BASE" HEAD_SHA="$EVENT_HEAD" \
      HEAD_REF=codex/test-carry-forward PR_AUTHOR="${PR_AUTHOR_OVERRIDE:-fixture-author}" \
      REPO=o/r DEFAULT_BRANCH=main \
      FINGERPRINT_RC="$fingerprint_rc" \
      FINGERPRINT_JSON="${FINGERPRINT_JSON_OVERRIDE:-{\"requires_review\":true,\"fingerprint\":\"fp-1\",\"reasons\":[\"protected path\"]\}}" \
      CARRY_RC="$carry_rc" CARRY_JSON="$carry_json" CLEARANCE_RC="$clearance_rc" \
      "$REAL_BASH" "$WORK/classifier.sh"
  ) >"$dir/out" 2>"$dir/err" || rc=$?
  printf '%s' "$rc"
}

last_output() { # <file> <key>
  awk -F= -v key="$2" '$1 == key { value=substr($0, length(key) + 2) } END { print value }' "$1"
}

C1="$WORK/classifier-carried"
rc=$(run_classifier "$C1" 0 0 '{"carried":true,"source_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_time":"2026-09-27T00:00:00Z"}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C1/output" needs_review)" = false ] \
   && [ "$(last_output "$C1/output" classification)" = carried-forward ] \
   && [ ! -f "$C1/clearance-call" ]; then
  pass "successful carry-forward publishes a reconcilable classification"
else
  fail "successful carry-forward left contradictory outputs (rc=$rc output=$(cat "$C1/output" 2>/dev/null) err=$(cat "$C1/err"))"
fi

C2="$WORK/classifier-carry-failed"
rc=$(run_classifier "$C2" 0 9 '{}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C2/output" needs_review)" = true ] \
   && [ "$(last_output "$C2/output" classification)" = fail-closed ] \
   && [[ "$(last_output "$C2/output" reasons)" == *'requiring review fail-closed'* ]] \
   && [ ! -f "$C2/clearance-call" ]; then
  pass "a failed carry-forward publishes a provenance-bearing fail-closed result"
else
  fail "failed carry-forward did not publish fail-closed outputs (rc=$rc output=$(cat "$C2/output" 2>/dev/null) err=$(cat "$C2/err"))"
fi

A6="$WORK/apply-carry-failed"
write_apply_fixture "$A6" "$HEAD40"
rc=$(run_apply "$A6" \
  "$(last_output "$C2/output" classification)" \
  "$(last_output "$C2/output" reasons)")
if [ "$rc" -eq 0 ] && [ "$(cat "$A6/label-writes" 2>/dev/null)" = added ] \
   && grep -Fq "mergepath-external-review-label:v1 head=$HEAD40 cause=fail-closed" "$A6/comment-writes" \
   && grep -Fq 'requiring review fail-closed' "$A6/comment-writes"; then
  pass "a carry lookup failure applies head-bound fail-closed provenance"
else
  fail "carry lookup failure did not apply reconcilable provenance (rc=$rc out=$(cat "$A6/out") err=$(cat "$A6/err"))"
fi

C4="$WORK/classifier-not-carried"
rc=$(run_classifier "$C4" 0 0 '{"carried":false}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C4/output" needs_review)" = true ] \
   && [ "$(last_output "$C4/output" classification)" = external-required ]; then
  pass "a successful carried-false lookup remains ordinary external-required"
else
  fail "carried-false lookup changed classification (rc=$rc output=$(cat "$C4/output" 2>/dev/null) err=$(cat "$C4/err"))"
fi

C5="$WORK/classifier-current-head-cleared"
rc=$(run_classifier "$C5" 0 0 '{"carried":false}' 0)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C5/output" needs_review)" = false ] \
   && [ "$(last_output "$C5/output" classification)" = external-cleared ] \
   && grep -q '^args=.*codex-review-check.sh 42 o/r$' "$C5/clearance-call" \
   && grep -q '^skip_ci=1$' "$C5/clearance-call" \
   && grep -q '^require_head=1$' "$C5/clearance-call" \
   && ! grep -Eq -- '--approval-readiness-only|--diagnostic-signal-only' "$C5/clearance-call"; then
  pass "current-head canonical clearance suppresses label application through the normal full gate"
else
  fail "current-head clearance did not use the normal canonical gate (rc=$rc output=$(cat "$C5/output" 2>/dev/null) call=$(cat "$C5/clearance-call" 2>/dev/null))"
fi

C6="$WORK/classifier-phase4b-cleared"
rc=$(run_classifier "$C6" 0 0 '{"carried":false}' 0)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C6/output" needs_review)" = false ] \
   && [ "$(last_output "$C6/output" classification)" = external-cleared ]; then
  pass "a canonical Phase 4b clearance suppresses duplicate external-review labeling"
else
  fail "Phase 4b canonical clearance was not honored (rc=$rc output=$(cat "$C6/output" 2>/dev/null))"
fi

C7="$WORK/classifier-clearance-hold"
rc=$(run_classifier "$C7" 0 0 '{"carried":false}' 1)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C7/output" needs_review)" = true ] \
   && [ "$(last_output "$C7/output" classification)" = external-required ]; then
  pass "a required finding or blocking hold remains ordinary external-required"
else
  fail "uncleared canonical gate suppressed review (rc=$rc output=$(cat "$C7/output" 2>/dev/null))"
fi

C8="$WORK/classifier-clearance-infra"
rc=$(run_classifier "$C8" 0 0 '{"carried":false}' 3)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C8/output" needs_review)" = true ] \
   && [ "$(last_output "$C8/output" classification)" = fail-closed ] \
   && [[ "$(last_output "$C8/output" reasons)" == *'requiring review fail-closed'* ]]; then
  pass "an unreadable canonical clearance fails classification closed"
else
  fail "canonical clearance infrastructure error did not fail closed (rc=$rc output=$(cat "$C8/output" 2>/dev/null))"
fi

C9="$WORK/classifier-stale-base-before-clearance"
mkdir -p "$C9"
jq -n --arg head "$EVENT_HEAD" --arg base "$OTHER_BASE40" '{head:$head,base:$base}' >"$C9/live-pair"
rc=$(run_classifier "$C9" 0 0 '{"carried":false}' 0)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C9/output" needs_review)" = false ] \
   && [ "$(last_output "$C9/output" classification)" = stale-event ] \
   && [ ! -f "$C9/clearance-call" ]; then
  pass "a retarget before clearance skips the stale event without claiming clearance"
else
  fail "pre-clearance retarget was not skipped safely (rc=$rc output=$(cat "$C9/output" 2>/dev/null))"
fi

C10="$WORK/classifier-base-moves-during-clearance"
mkdir -p "$C10"
jq -n --arg head "$EVENT_HEAD" --arg base "$EVENT_BASE" '{head:$head,base:$base}' >"$C10/live-pair"
jq -n --arg head "$EVENT_HEAD" --arg base "$OTHER_BASE40" '{head:$head,base:$base}' >"$C10/live-pair-2"
rc=$(run_classifier "$C10" 0 0 '{"carried":false}' 0)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C10/output" needs_review)" = false ] \
   && [ "$(last_output "$C10/output" classification)" = stale-event ]; then
  pass "a retarget during clearance prevents a stale clearance claim"
else
  fail "mid-clearance retarget was not skipped safely (rc=$rc output=$(cat "$C10/output" 2>/dev/null))"
fi

C11="$WORK/classifier-malformed-live-pair"
mkdir -p "$C11"
printf '{"head":"%s","base":"not-a-sha"}\n' "$EVENT_HEAD" >"$C11/live-pair"
rc=$(run_classifier "$C11" 0 0 '{"carried":false}' 0)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C11/output" needs_review)" = true ] \
   && [ "$(last_output "$C11/output" classification)" = fail-closed ]; then
  pass "a malformed live head/base pair fails clearance classification closed"
else
  fail "malformed live pair did not fail closed (rc=$rc output=$(cat "$C11/output" 2>/dev/null))"
fi

C12="$WORK/classifier-old-opened-rerun"
EVENT_ACTION_OVERRIDE=opened
export EVENT_ACTION_OVERRIDE
rc=$(run_classifier "$C12" 0 0 '{"carried":false}' 0)
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C12/output" needs_review)" = false ] \
   && [ "$(last_output "$C12/output" classification)" = external-cleared ] \
   && grep -q '^require_head=1$' "$C12/clearance-call"; then
  pass "an old opened native run recovers only through canonical exact-head clearance"
else
  fail "old opened run did not revalidate exact-head clearance (rc=$rc output=$(cat "$C12/output" 2>/dev/null))"
fi
C13="$WORK/classifier-old-opened-without-review"
rc=$(run_classifier "$C13" 0 0 '{"carried":false}' 1)
unset EVENT_ACTION_OVERRIDE
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C13/output" needs_review)" = true ] \
   && [ "$(last_output "$C13/output" classification)" = external-required ] \
   && [ -f "$C13/clearance-call" ]; then
  pass "an old opened run without exact-head clearance retains review even before its label arrives"
else
  fail "old opened run cleared without exact-head review (rc=$rc output=$(cat "$C13/output" 2>/dev/null))"
fi

C14="$WORK/classifier-missing-clearance-helper"
chmod -x "$CLASSIFIER_REPO/scripts/codex-review-check.sh"
rc=$(run_classifier "$C14" 0 0 '{"carried":false}' 0)
chmod +x "$CLASSIFIER_REPO/scripts/codex-review-check.sh"
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C14/output" needs_review)" = true ] \
   && [ "$(last_output "$C14/output" classification)" = fail-closed ] \
   && [ ! -f "$C14/clearance-call" ]; then
  pass "a missing trusted clearance helper cannot recover an old native failure"
else
  fail "missing trusted clearance helper did not fail closed (rc=$rc)"
fi

# Real classifier + fake private Git origin: no credentials or network.
for fetch_case in positive missing-token wrong-token wrong-origin missing-origin rewrite failure; do
  CF="$WORK/private-fetch-$fetch_case"
  CLASSIFIER_TOKEN_OVERRIDE=fake-classifier-read
  FETCH_ORIGIN_OVERRIDE=https://github.com/o/r
  FETCH_REWRITE_OVERRIDE=0 FETCH_FAIL_OVERRIDE=0
  case "$fetch_case" in
    missing-token) CLASSIFIER_TOKEN_OVERRIDE= ;;
    wrong-token) CLASSIFIER_TOKEN_OVERRIDE=wrong-fixture-read ;;
    wrong-origin) FETCH_ORIGIN_OVERRIDE=https://evil.invalid/o/r ;;
    missing-origin) FETCH_ORIGIN_OVERRIDE=missing ;;
    rewrite) FETCH_REWRITE_OVERRIDE=1 ;;
    failure) FETCH_FAIL_OVERRIDE=1 ;;
  esac
  export CLASSIFIER_TOKEN_OVERRIDE FETCH_ORIGIN_OVERRIDE FETCH_REWRITE_OVERRIDE FETCH_FAIL_OVERRIDE
  rc=$(run_classifier "$CF" 0 0 '{"carried":false}' 0)
  unset CLASSIFIER_TOKEN_OVERRIDE FETCH_ORIGIN_OVERRIDE FETCH_REWRITE_OVERRIDE FETCH_FAIL_OVERRIDE
  if [ "$fetch_case" = positive ]; then
    if [ "$rc" -eq 0 ] && [ "$(wc -l <"$CF/fetches" | tr -d ' ')" -eq 2 ] \
       && [ "$(last_output "$CF/output" classification)" = external-cleared ]; then
      pass "private-origin reads use verified temporary askpass without token argv or stored values"
    else fail "private-origin positive failed (rc=$rc err=$(cat "$CF/err"))"; fi
  elif [ "$rc" -ne 0 ] && ! grep -Fq 'classification=external-cleared' "$CF/output" 2>/dev/null; then
    pass "private-origin $fetch_case refuses clearance"
  else fail "private-origin $fetch_case did not fail closed (rc=$rc)"; fi
  cleanup_ok=1
  while IFS= read -r askpass_path; do
    [ ! -e "$askpass_path" ] && [ ! -e "$(dirname "$askpass_path")" ] || cleanup_ok=0
  done < <(cat "$CF/askpass-paths" 2>/dev/null || true)
  if [ "$cleanup_ok" -eq 1 ] \
     && ! grep -Fq fake-classifier-read "$CLASSIFIER_REPO/.git/config" \
     && ! grep -Fq fake-classifier-read "$CF/out" \
     && ! grep -Fq fake-classifier-read "$CF/err"; then
    pass "private-origin $fetch_case cleans its fetch-only helper and emits no token"
  else fail "private-origin $fetch_case leaked or retained its fetch credential helper"; fi
done

# The shared reader is used under two actual caller maps, not a claimed
# entirely read-only token in the trusted policy writer job.
if [ "$(yq -r '.permissions.contents' "$WORKFLOW")" = read ] \
   && [ "$(yq -r '.permissions.pull-requests' "$WORKFLOW")" = read ] \
   && [ "$(yq -r '.permissions.contents' "$TRUSTED_WORKFLOW")" = read ] \
   && [ "$(yq -r '.permissions.pull-requests' "$TRUSTED_WORKFLOW")" = write ] \
   && yq -r '.jobs."classify-and-mutate".steps[] | select(.id == "check") | .run' "$TRUSTED_WORKFLOW" | grep -Fq 'scripts/workflow/run-pr-policy-classifier.py'; then
  pass "native caller is entirely read-only; trusted workflow retains existing PR-write ownership and shares only Contents-read fetches"
else fail "classifier caller capability maps or shared trusted entrypoint drifted"; fi

C3="$WORK/classifier-fingerprint-failed"
rc=$(run_classifier "$C3" 8 0 '{}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C3/output" needs_review)" = true ] \
   && [ "$(last_output "$C3/output" classification)" = fail-closed ]; then
  pass "a failed fingerprint remains fail-closed"
else
  fail "fingerprint failure weakened fail-closed classification (rc=$rc output=$(cat "$C3/output" 2>/dev/null) err=$(cat "$C3/err"))"
fi

# Dependabot action-pin bump lane (#2164): the classifier consults the trusted
# helper only for a dependabot[bot] PR whose sole external-review reason is the
# protected-path rule, pins it to the event pair and the governing base config,
# and turns an exempt verdict into a no-review classification. Every other
# verdict keeps the ordinary path.
PIN_FP='{"requires_review":true,"fingerprint":"fp-1","lines_changed":2,"threshold":100,"reasons":["protected paths modified: .github/workflows/ci.yml"]}'
PIN_EXEMPT_JSON=$(jq -nc --arg h "$EVENT_HEAD" --arg b "$EVENT_BASE" '{exempt:true,status:"exempt",reason:"every changed line is a Dependabot action pin bump",head:$h,base:$b,author:"dependabot[bot]",provenance:"all 1 commit(s) authored by dependabot[bot], committed by GitHub, signature verified",files:[{filename:".github/workflows/ci.yml",pins:1}],pins:1}')

D1="$WORK/classifier-pin-bump-exempt"
rc=$(PR_AUTHOR_OVERRIDE='dependabot[bot]' FINGERPRINT_JSON_OVERRIDE="$PIN_FP" PIN_RC=0 PIN_JSON="$PIN_EXEMPT_JSON" \
  run_classifier "$D1" 0 0 '{"carried":false}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$D1/output" needs_review)" = false ] \
   && [ "$(last_output "$D1/output" classification)" = dependabot-pin-bump ] \
   && [ "$(last_output "$D1/output" dependabot_pin_bump)" = true ] \
   && [ "$(last_output "$D1/output" dependabot_pin_bump_evidence)" = "$PIN_EXEMPT_JSON" ] \
   && [ ! -f "$D1/clearance-call" ]; then
  pass "a verified Dependabot pin-only bump classifies dependabot-pin-bump with its evidence and skips the clearance scan"
else
  fail "pin-bump exempt verdict did not publish a no-review classification (rc=$rc output=$(cat "$D1/output" 2>/dev/null) err=$(cat "$D1/err"))"
fi
pin_call=$(cat "$D1/pin-call" 2>/dev/null || true)
if [[ "$pin_call" == *"--head $EVENT_HEAD --base $EVENT_BASE --config "*"/.github/review-policy.yml --files-json "* ]] \
   && [[ "$pin_call" != *"--config $CLASSIFIER_REPO/.github/review-policy.yml"* ]] \
   && [[ "$pin_call" == "$CLASSIFIER_REPO/scripts/workflow/dependabot_pin_bump_exemption.sh --repo o/r --pr 42 "* ]]; then
  pass "the lane helper runs from the trusted default checkout, pinned to the event pair, with the base config and the fetched files payload"
else
  fail "lane helper invocation is wrong: $pin_call"
fi

D2="$WORK/classifier-pin-bump-not-exempt"
rc=$(PR_AUTHOR_OVERRIDE='dependabot[bot]' FINGERPRINT_JSON_OVERRIDE="$PIN_FP" PIN_RC=1 \
  PIN_JSON='{"exempt":false,"status":"not-exempt","reason":"file .github/workflows/ci.yml: hunk 1 adds a line that is not an action pin"}' \
  run_classifier "$D2" 0 0 '{"carried":false}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$D2/output" needs_review)" = true ] \
   && [ "$(last_output "$D2/output" classification)" = external-required ] \
   && [ "$(last_output "$D2/output" dependabot_pin_bump)" = false ] \
   && grep -Fq 'not an action pin' "$D2/out"; then
  pass "a Dependabot diff with a non-pin hunk keeps the ordinary external-required classification"
else
  fail "pin-bump not-exempt verdict changed classification (rc=$rc output=$(cat "$D2/output" 2>/dev/null) err=$(cat "$D2/err"))"
fi

D3="$WORK/classifier-pin-bump-unreadable"
rc=$(PR_AUTHOR_OVERRIDE='dependabot[bot]' FINGERPRINT_JSON_OVERRIDE="$PIN_FP" PIN_RC=3 \
  PIN_JSON='{"exempt":false,"status":"unreadable","reason":"commit provenance could not be verified"}' \
  run_classifier "$D3" 0 0 '{"carried":false}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$D3/output" needs_review)" = true ] \
   && [ "$(last_output "$D3/output" dependabot_pin_bump)" = false ] \
   && grep -Fq 'could not be reached' "$D3/out"; then
  pass "an unreachable pin-bump verdict requires review fail-closed"
else
  fail "unreachable pin-bump verdict weakened the classification (rc=$rc output=$(cat "$D3/output" 2>/dev/null) err=$(cat "$D3/err"))"
fi

D4="$WORK/classifier-pin-bump-over-threshold"
rc=$(PR_AUTHOR_OVERRIDE='dependabot[bot]' \
  FINGERPRINT_JSON_OVERRIDE='{"requires_review":true,"fingerprint":"fp-1","lines_changed":400,"threshold":100,"reasons":["400 lines changed >= threshold 100","protected paths modified: .github/workflows/ci.yml"]}' \
  PIN_RC=0 PIN_JSON="$PIN_EXEMPT_JSON" \
  run_classifier "$D4" 0 0 '{"carried":false}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$D4/output" needs_review)" = true ] \
   && [ ! -f "$D4/pin-call" ] \
   && grep -Fq 'more than the protected-path rule' "$D4/out"; then
  pass "a Dependabot diff that also crosses the threshold is not lane-eligible and never consults the helper"
else
  fail "threshold-crossing Dependabot diff reached the lane (rc=$rc output=$(cat "$D4/output" 2>/dev/null) err=$(cat "$D4/err"))"
fi

D5="$WORK/classifier-pin-bump-human-author"
rc=$(FINGERPRINT_JSON_OVERRIDE="$PIN_FP" PIN_RC=0 PIN_JSON="$PIN_EXEMPT_JSON" \
  run_classifier "$D5" 0 0 '{"carried":false}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$D5/output" needs_review)" = true ] \
   && [ "$(last_output "$D5/output" dependabot_pin_bump)" = false ] \
   && [ ! -f "$D5/pin-call" ]; then
  pass "a non-Dependabot author never reaches the lane, whatever the helper would say"
else
  fail "non-Dependabot author reached the lane (rc=$rc output=$(cat "$D5/output" 2>/dev/null) err=$(cat "$D5/err"))"
fi

RECONCILE_IF=$(yq -r '.jobs."classify-and-mutate".steps[] | select(.name == "Reconcile a policy-owned fail-closed label") | .if' "$TRUSTED_WORKFLOW")
if [[ "$RECONCILE_IF" == *"under-threshold"* ]] && [[ "$RECONCILE_IF" == *"carried-forward"* ]]; then
  pass "reconciliation accepts ordinary and carried-forward no-review classifications"
else
  fail "reconciliation condition excludes a no-review classification: $RECONCILE_IF"
fi

application_comment_body() { # <optional marker> <reason>
  local marker=$1 reason=$2
  if [ -n "$marker" ]; then
    printf '%s\n' "$marker"
  fi
  printf '%s\n\n%s\n\n%s\n\n%s\n\n%s' \
    '**External Review Required**' \
    'This PR has been labeled `needs-external-review` based on .github/review-policy.yml:' \
    "$reason" \
    'Per REVIEW_POLICY.md, the authoring agent must post a handoff message and alert the human. The human will coordinate external review by a different agent.' \
    '> Automated check per .github/review-policy.yml'
}

LEGACY_INCIDENT_REASON='- Could not fetch PR files for external-review fingerprint; requiring review fail-closed'

write_reconcile_fixture() { # <dir> <latest actor> <comment time> [event]
  local dir=$1 actor=$2 comment_time=$3 event=${4:-labeled} body
  mkdir -p "$dir"
  cat >"$dir/live.json" <<JSON
{"head":{"sha":"$HEAD40"},"base":{"sha":"$BASE40"},"labels":[{"name":"needs-external-review"}]}
JSON
  cat >"$dir/timeline.json" <<JSON
[{"id":91,"event":"$event","label":{"name":"needs-external-review"},"actor":{"login":"$actor"},"created_at":"2026-09-25T01:36:05Z","commit_id":"$HEAD40"}]
JSON
  body=$(application_comment_body '' "$LEGACY_INCIDENT_REASON")
  jq -n --arg created_at "$comment_time" --arg body "$body" \
    '[{"id":92,"user":{"login":"github-actions[bot]"},"created_at":$created_at,"body":$body}]' \
    >"$dir/comments.json"
}

run_reconcile() { # <fixture-dir>
  local dir=$1 rc=0
  env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" GH_STUB_DIR="$dir" \
    GH_TOKEN=fake-read LABEL_REMOVAL_TOKEN="${LABEL_REMOVAL_TOKEN_OVERRIDE-fake-write}" \
    PR_NUMBER=42 EXPECTED_HEAD_SHA="$HEAD40" EXPECTED_BASE_SHA="$BASE40" REPO=o/r \
    bash "$WORK/reconcile.sh" >"$dir/out" 2>"$dir/err" || rc=$?
  printf '%s' "$rc"
}

R1="$WORK/reconcile-owned"
write_reconcile_fixture "$R1" 'github-actions[bot]' '2026-09-25T01:36:20Z'
rc=$(run_reconcile "$R1")
if [ "$rc" -eq 0 ] && [ "$(cat "$R1/deletes" 2>/dev/null)" = deleted ] \
   && [ "$(grep -c '^api --paginate repos/o/r/issues/42/timeline$' "$R1/calls")" -eq 2 ]; then
  pass "latest automation label plus adjacent fail-closed comment is reconciled after repeat readback (#1321)"
else
  fail "owned fail-closed label was not reconciled safely (rc=$rc out=$(cat "$R1/out") err=$(cat "$R1/err"))"
fi

R2="$WORK/reconcile-human"
write_reconcile_fixture "$R2" human-owner '2026-09-25T01:36:20Z'
rc=$(run_reconcile "$R2")
if [ "$rc" -eq 0 ] && [ ! -f "$R2/deletes" ]; then
  pass "a human's latest label event is preserved despite an old automation comment (#1321)"
else
  fail "human-applied label was not preserved (rc=$rc)"
fi

R3="$WORK/reconcile-old-comment"
write_reconcile_fixture "$R3" 'github-actions[bot]' '2026-09-25T01:20:00Z'
rc=$(run_reconcile "$R3")
if [ "$rc" -eq 0 ] && [ ! -f "$R3/deletes" ]; then
  pass "a non-adjacent historical fail-closed comment does not prove current ownership (#1321)"
else
  fail "historical comment incorrectly authorized removal (rc=$rc)"
fi

R4="$WORK/reconcile-head-move"
write_reconcile_fixture "$R4" 'github-actions[bot]' '2026-09-25T01:36:20Z'
cat >"$R4/live-2.json" <<JSON
{"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"base":{"sha":"$BASE40"},"labels":[{"name":"needs-external-review"}]}
JSON
rc=$(run_reconcile "$R4")
if [ "$rc" -eq 0 ] && [ ! -f "$R4/deletes" ]; then
  pass "a head move preserves the label without failing successful classification (#1321)"
else
  fail "head move did not hold reconciliation (rc=$rc)"
fi

R4B="$WORK/reconcile-base-moved-before"
write_reconcile_fixture "$R4B" 'github-actions[bot]' '2026-09-25T01:36:20Z'
jq --arg base "$OTHER_BASE40" '.base.sha = $base' "$R4B/live.json" >"$R4B/live.tmp"
mv "$R4B/live.tmp" "$R4B/live.json"
rc=$(run_reconcile "$R4B")
if [ "$rc" -eq 0 ] && [ ! -f "$R4B/deletes" ]; then
  pass "a base retarget before reconciliation preserves the label (#1321)"
else
  fail "pre-reconciliation base retarget did not preserve the label (rc=$rc)"
fi

R4C="$WORK/reconcile-base-moved-during"
write_reconcile_fixture "$R4C" 'github-actions[bot]' '2026-09-25T01:36:20Z'
jq --arg base "$OTHER_BASE40" '.base.sha = $base' "$R4C/live.json" >"$R4C/live-2.json"
rc=$(run_reconcile "$R4C")
if [ "$rc" -eq 0 ] && [ ! -f "$R4C/deletes" ]; then
  pass "a base retarget during reconciliation preserves the label (#1321)"
else
  fail "mid-reconciliation base retarget did not preserve the label (rc=$rc)"
fi

R4D="$WORK/reconcile-malformed-base"
write_reconcile_fixture "$R4D" 'github-actions[bot]' '2026-09-25T01:36:20Z'
jq '.base.sha = "not-a-sha"' "$R4D/live.json" >"$R4D/live.tmp"
mv "$R4D/live.tmp" "$R4D/live.json"
rc=$(run_reconcile "$R4D")
if [ "$rc" -eq 0 ] && [ ! -f "$R4D/deletes" ]; then
  pass "a malformed live base preserves the label (#1321)"
else
  fail "malformed reconciliation base did not preserve the label (rc=$rc)"
fi

R5="$WORK/reconcile-read-failure"
write_reconcile_fixture "$R5" 'github-actions[bot]' '2026-09-25T01:36:20Z'
touch "$R5/fail-timeline"
rc=$(run_reconcile "$R5")
if [ "$rc" -eq 0 ] && [ ! -f "$R5/deletes" ]; then
  pass "an unreadable timeline preserves the label without failing successful classification (#1321)"
else
  fail "timeline read failure did not hold reconciliation (rc=$rc)"
fi

R6="$WORK/reconcile-marker-mismatch"
write_reconcile_fixture "$R6" 'github-actions[bot]' '2026-09-25T01:36:20Z'
body=$(application_comment_body \
  '<!-- mergepath-external-review-label:v1 head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cause=fail-closed -->' \
  '- Could not read policy; requiring review fail-closed')
jq --arg body "$body" '.[] .body = $body' \
  "$R6/comments.json" >"$R6/comments.tmp"
mv "$R6/comments.tmp" "$R6/comments.json"
rc=$(run_reconcile "$R6")
if [ "$rc" -eq 0 ] && [ ! -f "$R6/deletes" ]; then
  pass "a head marker that disagrees with the classified PR head does not authorize removal (#1321)"
else
  fail "mismatched provenance marker authorized removal (rc=$rc)"
fi

R7="$WORK/reconcile-missing-token"
write_reconcile_fixture "$R7" 'github-actions[bot]' '2026-09-25T01:36:20Z'
LABEL_REMOVAL_TOKEN_OVERRIDE=
export LABEL_REMOVAL_TOKEN_OVERRIDE
rc=$(run_reconcile "$R7")
unset LABEL_REMOVAL_TOKEN_OVERRIDE
if [ "$rc" -eq 0 ] && [ ! -f "$R7/deletes" ]; then
  pass "a missing removal token preserves the label without failing successful classification (#1321)"
else
  fail "missing removal token did not preserve the label cleanly (rc=$rc)"
fi

R8="$WORK/reconcile-delete-failure"
write_reconcile_fixture "$R8" 'github-actions[bot]' '2026-09-25T01:36:20Z'
touch "$R8/fail-delete"
rc=$(run_reconcile "$R8")
if [ "$rc" -eq 0 ] && [ ! -f "$R8/deletes" ]; then
  pass "a failed removal preserves the label for live Label Gate evaluation (#1321)"
else
  fail "failed removal did not preserve the label cleanly (rc=$rc)"
fi

R9="$WORK/reconcile-matching-marker"
write_reconcile_fixture "$R9" 'github-actions[bot]' '2026-09-25T01:36:20Z'
body=$(application_comment_body \
  "<!-- mergepath-external-review-label:v1 head=$HEAD40 cause=fail-closed -->" \
  '- Could not read policy; requiring review fail-closed')
jq --arg body "$body" '.[] .body = $body' \
  "$R9/comments.json" >"$R9/comments.tmp"
mv "$R9/comments.tmp" "$R9/comments.json"
rc=$(run_reconcile "$R9")
if [ "$rc" -eq 0 ] && [ "$(cat "$R9/deletes" 2>/dev/null)" = deleted ]; then
  pass "a provenance marker matching the classified PR head can authorize removal (#1321)"
else
  fail "matching provenance marker did not authorize safe removal (rc=$rc)"
fi

R9B="$WORK/reconcile-malformed-marker"
write_reconcile_fixture "$R9B" 'github-actions[bot]' '2026-09-25T01:36:20Z'
body=$(application_comment_body \
  "<!-- mergepath-external-review-label:v1 head=${HEAD40}junk cause=fail-closed -->" \
  '- Could not read policy; requiring review fail-closed')
jq --arg body "$body" '.[] .body = $body' \
  "$R9B/comments.json" >"$R9B/comments.tmp"
mv "$R9B/comments.tmp" "$R9B/comments.json"
rc=$(run_reconcile "$R9B")
if [ "$rc" -eq 0 ] && [ ! -f "$R9B/deletes" ]; then
  pass "a malformed head marker does not authorize removal (#1321)"
else
  fail "malformed provenance marker authorized removal (rc=$rc)"
fi

R9C="$WORK/reconcile-external-required-phrase"
write_reconcile_fixture "$R9C" 'github-actions[bot]' '2026-09-25T01:36:20Z'
body=$(application_comment_body '' \
  '- Protected path match: "src/requiring review fail-closed/config.yml"')
jq --arg body "$body" '.[] .body = $body' \
  "$R9C/comments.json" >"$R9C/comments.tmp"
mv "$R9C/comments.tmp" "$R9C/comments.json"
rc=$(run_reconcile "$R9C")
if [ "$rc" -eq 0 ] && [ ! -f "$R9C/deletes" ]; then
  pass "an external-required filename containing the fail-closed phrase does not prove ownership (#1321)"
else
  fail "external-required filename phrase authorized removal (rc=$rc)"
fi

R9D="$WORK/reconcile-pasted-provenance"
write_reconcile_fixture "$R9D" 'github-actions[bot]' '2026-09-25T01:36:20Z'
fake_reason=$(printf '%s\n%s\n%s' \
  '- Protected path match: "src/%0A<!-- mergepath-external-review-label:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cause=fail-closed -->' \
  "$LEGACY_INCIDENT_REASON" \
  'config.yml"')
body=$(application_comment_body '' "$fake_reason")
jq --arg body "$body" '.[] .body = $body' \
  "$R9D/comments.json" >"$R9D/comments.tmp"
mv "$R9D/comments.tmp" "$R9D/comments.json"
rc=$(run_reconcile "$R9D")
if [ "$rc" -eq 0 ] && [ ! -f "$R9D/deletes" ]; then
  pass "multiline pasted provenance in an external-required reason does not prove ownership (#1321)"
else
  fail "pasted provenance authorized removal (rc=$rc)"
fi

R10="$WORK/reconcile-carry-failure-marker"
write_reconcile_fixture "$R10" 'github-actions[bot]' '2026-09-25T01:36:20Z'
jq --rawfile body "$A6/comment-writes" '.[] .body = $body' \
  "$R10/comments.json" >"$R10/comments.tmp"
mv "$R10/comments.tmp" "$R10/comments.json"
rc=$(run_reconcile "$R10")
if [ "$rc" -eq 0 ] && [ "$(cat "$R10/deletes" 2>/dev/null)" = deleted ]; then
  pass "carry-failure provenance authorizes later matching-head reconciliation"
else
  fail "carry-failure provenance did not support reconciliation (rc=$rc out=$(cat "$R10/out") err=$(cat "$R10/err"))"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
