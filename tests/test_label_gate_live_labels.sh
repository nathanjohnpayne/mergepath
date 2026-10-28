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
WORKFLOW="${LABEL_GATE_TEST_WORKFLOW:-$ROOT/.github/workflows/pr-review-policy.yml}"
# The External Review Check's `check` step runs this script (#2727 slice 3b).
CLASSIFIER_SCRIPT="${LABEL_GATE_TEST_CLASSIFIER:-$ROOT/scripts/workflow/external_review_classify.sh}"
AGENT_WORKFLOW="$ROOT/.github/workflows/agent-review.yml"

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
CLASSIFIER_RUN=$(yq -r '.jobs."external-review-labeling".steps[] | select(.id == "check") | .run' "$WORKFLOW")
CLASSIFIER_BODY=$(cat "$CLASSIFIER_SCRIPT")

# #2727 slice 3b: the check step runs the DEFAULT BRANCH's classifier blob,
# never the candidate checkout's copy (#2775: this job holds the CI-actor
# PAT), and fails closed when the default branch has none. Executed, not
# grepped: a fixture clone whose origin/main does or does not carry a stub
# classifier, while the candidate tree always carries a hostile one.
STEP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/label-gate-step.XXXXXX")
step_git() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
run_check_step() { # <with-default-copy: yes|no> -> prints "<rc>|<output file>|<log>"
  local d="$STEP_WORK/$1" rc=0
  step_git init -q "$d/upstream"
  mkdir -p "$d/upstream/scripts/workflow"
  if [ "$1" = yes ]; then
    printf '%s\n' 'echo "classification=from-default-branch" >> "$GITHUB_OUTPUT"' \
      >"$d/upstream/scripts/workflow/external_review_classify.sh"
  else
    printf 'x\n' >"$d/upstream/README"
  fi
  step_git -C "$d/upstream" add -A && step_git -C "$d/upstream" commit -q -m base
  step_git clone -q "$d/upstream" "$d/checkout"
  step_git -C "$d/checkout" checkout -q -b candidate
  mkdir -p "$d/checkout/scripts/workflow"
  printf '%s\n' 'echo "classification=from-candidate" >> "$GITHUB_OUTPUT"' 'touch "$CANDIDATE_RAN"' \
    >"$d/checkout/scripts/workflow/external_review_classify.sh"
  printf '%s\n' "$CLASSIFIER_RUN" >"$d/step.sh"
  ( cd "$d/checkout" && env DEFAULT_BRANCH=main GITHUB_OUTPUT="$d/output" CANDIDATE_RAN="$d/candidate-ran" \
      bash --noprofile --norc -eo pipefail "$d/step.sh" ) >"$d/log" 2>&1 || rc=$?
  printf '%s|%s|%s' "$rc" "$d/output" "$d/candidate-ran"
}
IFS='|' read -r step_rc step_out step_cand <<<"$(run_check_step yes)"
if [ "$step_rc" = 0 ] && grep -qx 'classification=from-default-branch' "$step_out" \
   && ! grep -q 'from-candidate' "$step_out" && [ ! -e "$step_cand" ]; then
  pass "the check step runs the default branch's classifier, not the candidate's (#2727 3b / #2775)"
else
  fail "the check step must run origin/main's classifier only (rc=$step_rc output=$(cat "$step_out" 2>/dev/null))"
fi
IFS='|' read -r step_rc step_out step_cand <<<"$(run_check_step no)"
if [ "$step_rc" = 0 ] && grep -qx 'needs_review=true' "$step_out" \
   && grep -qx 'classification=fail-closed' "$step_out" \
   && ! grep -q 'from-candidate' "$step_out" && [ ! -e "$step_cand" ]; then
  pass "without a default-branch classifier the check step fails closed and runs no candidate copy"
else
  fail "a missing default-branch classifier must fail closed without the candidate copy (rc=$step_rc output=$(cat "$step_out" 2>/dev/null))"
fi
rm -rf "$STEP_WORK"
APPLY_IF=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Apply label and comment") | .if' "$WORKFLOW")
if [[ "$CLASSIFIER_BODY" != *'label_lifecycle_event=true'* ]] \
   && [[ "$APPLY_IF" == *"github.event.action == 'unlabeled'"* ]] \
   && [[ "$APPLY_IF" == *"github.event.label.name == 'needs-external-review'"* ]]; then
  pass "needs-external-review removals are classified without being immediately re-added (#1254/#969)"
else
  fail "label lifecycle classification/apply boundary is missing"
fi

# GitHub compiles any run scalar containing an expression as one format
# expression, which has a 21,000-character registration limit. Event values
# reach the classifier through its step env. Since the body moved into a
# script (#2727 slice 3b), an expression in it would also never be expanded,
# so the script must contain none.
CLASSIFIER_RUN_BYTES=$(printf '%s' "$CLASSIFIER_RUN" | LC_ALL=C wc -c | tr -d ' ')
CLASSIFIER_ENV=$(yq -o=json -I=0 '.jobs."external-review-labeling".steps[] | select(.id == "check") | .env' "$WORKFLOW")
if jq -e '
        .BASE_SHA == "${{ github.event.pull_request.base.sha }}"
        and .HEAD_SHA == "${{ github.event.pull_request.head.sha }}"
        and .HEAD_REF == "${{ github.event.pull_request.head.ref }}"
        and .PR_AUTHOR == "${{ github.event.pull_request.user.login }}"
        and .REPO == "${{ github.repository }}"
        and .DEFAULT_BRANCH == "${{ github.event.repository.default_branch }}"
      ' <<<"$CLASSIFIER_ENV" >/dev/null \
   && [ "$CLASSIFIER_RUN_BYTES" -le 21000 ] && [[ "$CLASSIFIER_BODY" != *'${{'* ]]; then
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
yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Reconcile a policy-owned fail-closed label") | .run' \
  "$WORKFLOW" >"$WORK/reconcile.sh"
if [ ! -s "$WORK/reconcile.sh" ]; then
  fail "could not extract the fail-closed label reconciliation step"
else
  pass "fail-closed label reconciliation step is present"
fi

yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Apply label and comment") | .run' \
  "$WORKFLOW" | sed 's|${{ github.repository }}|o/r|g' >"$WORK/apply.sh"
if [ ! -s "$WORK/apply.sh" ]; then
  fail "could not extract the label application step"
else
  pass "label application step is present"
fi

yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Propagation PR review lane") | .run' \
  "$WORKFLOW" | sed 's|${{ github.repository }}|o/r|g' >"$WORK/propagation.sh"
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
  "pr view 42 --repo o/r --json comments --jq .comments[].body")
    # Model gh pr view's bounded connection for the known-bad control.
    awk 'NR <= 100' "$GH_STUB_DIR/pr-comments.txt" ;;
  "api --paginate repos/o/r/issues/42/comments --jq .[].body")
    printf 'page-1\n' >>"$GH_STUB_DIR/comment-pages"
    awk 'NR <= 100' "$GH_STUB_DIR/pr-comments.txt"
    if [ "$(wc -l <"$GH_STUB_DIR/pr-comments.txt")" -gt 100 ]; then
      printf 'page-2\n' >>"$GH_STUB_DIR/comment-pages"
      if [ -f "$GH_STUB_DIR/fail-later-comment-page" ]; then
        printf '{"message":"fixture page two failed"}\n'
        echo 'gh: fixture page two failed (HTTP 503)' >&2
        exit 1
      fi
      awk 'NR > 100' "$GH_STUB_DIR/pr-comments.txt"
    fi ;;
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
    printf '%s' "${7-}" >>"$GH_STUB_DIR/comment-writes"
    # Subsequent label/edit deliveries see comments the earlier run posted.
    if [ -f "$GH_STUB_DIR/pr-comments.txt" ]; then
      printf '%s\n' "${7-}" >>"$GH_STUB_DIR/pr-comments.txt"
    fi ;;
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

# #1501: marker lookup must finish all pages before deciding whether the
# pair has already been published. Each noise line is one fixture comment.
write_long_propagation_history() { # <fixture-dir>
  local dir=$1
  awk 'BEGIN { for (i = 1; i <= 150; i++) print "fixture unrelated comment " i }' \
    >"$dir/pr-comments.txt"
}
P1E="$WORK/propagation-existing-page-two"
write_propagation_fixture "$P1E" "$HEAD40"
write_long_propagation_history "$P1E"
printf '%s\n' "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" >>"$P1E/pr-comments.txt"
for delivery in labeled edited; do
  rc=$(EVENT_ACTION="$delivery" run_propagation "$P1E")
  if [ "$rc" -eq 0 ] && [ ! -f "$P1E/comment-writes" ] && [ ! -f "$P1E/dispatches" ]; then
    pass "later-page current-pair marker suppresses duplicate publication on $delivery"
  else
    fail "later-page marker missed on $delivery (rc=$rc out=$(cat "$P1E/out") err=$(cat "$P1E/err"))"
  fi
done
if [ "$(grep -c '^page-2$' "$P1E/comment-pages" 2>/dev/null || true)" = 2 ]; then
  pass 'both repeated deliveries completely read the later comment page'
else
  fail 'repeated deliveries did not complete pagination'
fi

P1F="$WORK/propagation-absent-long-history"
write_propagation_fixture "$P1F" "$HEAD40"
write_long_propagation_history "$P1F"
for delivery in opened labeled edited; do
  rc=$(EVENT_ACTION="$delivery" run_propagation "$P1F")
  if [ "$rc" -ne 0 ]; then
    fail "long-history publication failed on $delivery (rc=$rc err=$(cat "$P1F/err"))"
  fi
done
if [ "$(grep -Fc "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" "$P1F/comment-writes" 2>/dev/null || true)" = 1 ] \
   && [ "$(grep -c '^dispatched$' "$P1F/dispatches" 2>/dev/null || true)" = 1 ] \
   && [ "$(grep -c '^page-2$' "$P1F/comment-pages" 2>/dev/null || true)" = 3 ]; then
  pass 'absent marker publishes once; later label/edit deliveries do not repeat comment or dispatch'
else
  fail 'long-history repeated deliveries duplicated or omitted publication'
fi

P1G="$WORK/propagation-other-head-page-two"
write_propagation_fixture "$P1G" "$HEAD40"
write_long_propagation_history "$P1G"
printf '%s\n' "<!-- mergepath-propagation-lane:v2 verified-head=$OTHER_HEAD40 verified-base=$BASE40 -->" >>"$P1G/pr-comments.txt"
rc=$(run_propagation "$P1G")
if [ "$rc" -eq 0 ] && [ -s "$P1G/comment-writes" ] \
   && grep -Fq "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" "$P1G/comment-writes" \
   && [ "$(cat "$P1G/dispatches" 2>/dev/null)" = dispatched ]; then
  pass "another head's later-page marker does not suppress current-pair publication"
else
  fail "other-head marker suppressed publication (rc=$rc out=$(cat "$P1G/out") err=$(cat "$P1G/err"))"
fi

for earlier_marker in absent present; do
  P1H="$WORK/propagation-failed-page-two-$earlier_marker"
  write_propagation_fixture "$P1H" "$HEAD40"
  write_long_propagation_history "$P1H"
  if [ "$earlier_marker" = present ]; then
    # Even seeing a marker on page one cannot excuse an incomplete read.
    printf '%s\n' "<!-- mergepath-propagation-lane:v2 verified-head=$HEAD40 verified-base=$BASE40 -->" >"$P1H/marker"
    cat "$P1H/marker" "$P1H/pr-comments.txt" >"$P1H/history"
    mv "$P1H/history" "$P1H/pr-comments.txt"
  fi
  touch "$P1H/fail-later-comment-page"
  rc=$(run_propagation "$P1H")
  if [ "$rc" -ne 0 ] && [ ! -f "$P1H/comment-writes" ] \
     && [ ! -f "$P1H/dispatches" ] && [ ! -f "$P1H/label-removals" ] \
     && grep -q '^page-2$' "$P1H/comment-pages" \
     && grep -Fq 'Could not read complete propagation-lane marker history' "$P1H/err"; then
    pass "failed later page refuses all writes with earlier marker $earlier_marker"
  else
    fail "failed later page became usable history ($earlier_marker rc=$rc out=$(cat "$P1H/out") err=$(cat "$P1H/err"))"
  fi
done

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

cp "$CLASSIFIER_SCRIPT" "$WORK/classifier.sh"

run_classifier() { # <fixture-dir> <fingerprint-rc> <carry-rc> <carry-json> [clearance-rc]
  local dir=$1 fingerprint_rc=$2 carry_rc=$3 carry_json=$4 clearance_rc=${5:-1} rc=0
  mkdir -p "$dir"
  if [ ! -f "$dir/live-pair" ]; then
    jq -n --arg head "$EVENT_HEAD" --arg base "$EVENT_BASE" '{head:$head,base:$base}' \
      >"$dir/live-pair"
  fi
  (
    cd "$CLASSIFIER_REPO"
    env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" GH_STUB_DIR="$dir" \
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

C12="$WORK/classifier-non-label-event"
EVENT_ACTION_OVERRIDE=synchronize
export EVENT_ACTION_OVERRIDE
rc=$(run_classifier "$C12" 0 0 '{"carried":false}' 0)
unset EVENT_ACTION_OVERRIDE
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C12/output" needs_review)" = true ] \
   && [ "$(last_output "$C12/output" classification)" = external-required ] \
   && [ ! -f "$C12/clearance-call" ]; then
  pass "non-label deliveries keep their existing classification path and skip the full clearance scan"
else
  fail "canonical clearance scan broadened beyond label events (rc=$rc output=$(cat "$C12/output" 2>/dev/null))"
fi

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
   && [[ "$pin_call" != "$CLASSIFIER_REPO/scripts/workflow/dependabot_pin_bump_exemption.sh "* ]] \
   && [[ "$pin_call" == *"/scripts/workflow/dependabot_pin_bump_exemption.sh --repo o/r --pr 42 "* ]]; then
  pass "the lane helper runs from the trusted base worktree, pinned to the event pair, with the base config and the fetched files payload"
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

RECONCILE_IF=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Reconcile a policy-owned fail-closed label") | .if' "$WORKFLOW")
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
