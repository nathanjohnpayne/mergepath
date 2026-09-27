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
APPLY_IF=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Apply label and comment") | .if' "$WORKFLOW")
if [[ "$CLASSIFIER_BODY" != *'label_lifecycle_event=true'* ]] \
   && [[ "$APPLY_IF" == *"github.event.action == 'unlabeled'"* ]] \
   && [[ "$APPLY_IF" == *"github.event.label.name == 'needs-external-review'"* ]]; then
  pass "needs-external-review removals are classified without being immediately re-added (#1254/#969)"
else
  fail "label lifecycle classification/apply boundary is missing"
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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
