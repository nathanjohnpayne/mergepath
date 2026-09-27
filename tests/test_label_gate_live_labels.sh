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

mkdir -p "$WORK/bin"
REAL_BASH=$(command -v bash)
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls"
case "$*" in
  "api --paginate repos/o/r/pulls/42/files")
    printf '[{"filename":"src/example.sh","status":"modified","additions":400,"deletions":0}]\n' ;;
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
  */external_review_fingerprint.sh)
    [ "${FINGERPRINT_RC:-0}" -eq 0 ] || exit "$FINGERPRINT_RC"
    printf '%s\n' "${FINGERPRINT_JSON:?}" ;;
  */external_review_carryforward.sh)
    [ "${CARRY_RC:-0}" -eq 0 ] || exit "$CARRY_RC"
    printf '%s\n' "${CARRY_JSON:?}" ;;
  *) exec "$REAL_BASH" "$@" ;;
esac
SH
chmod +x "$WORK/bin/bash"

yq -r '.jobs."external-review-labeling".steps[] | select(.id == "check") | .run' \
  "$WORKFLOW" \
  | sed \
      -e "s|\${{ github.event.pull_request.base.sha }}|$(git -C "$ROOT" rev-parse HEAD^)|g" \
      -e "s|\${{ github.event.pull_request.head.sha }}|$(git -C "$ROOT" rev-parse HEAD)|g" \
      -e 's|${{ github.event.pull_request.head.ref }}|codex/test-carry-forward|g' \
      -e 's|${{ github.event.pull_request.user.login }}|fixture-author|g' \
      -e 's|${{ github.event.repository.default_branch }}|main|g' \
      -e 's|${{ github.repository }}|o/r|g' \
  >"$WORK/classifier.sh"

run_classifier() { # <fixture-dir> <fingerprint-rc> <carry-rc> <carry-json>
  local dir=$1 fingerprint_rc=$2 carry_rc=$3 carry_json=$4 rc=0
  mkdir -p "$dir"
  env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" GH_STUB_DIR="$dir" \
    GITHUB_OUTPUT="$dir/output" PR_NUMBER=42 \
    FINGERPRINT_RC="$fingerprint_rc" \
    FINGERPRINT_JSON='{"requires_review":true,"fingerprint":"fp-1","reasons":["protected path"]}' \
    CARRY_RC="$carry_rc" CARRY_JSON="$carry_json" \
    "$REAL_BASH" "$WORK/classifier.sh" >"$dir/out" 2>"$dir/err" || rc=$?
  printf '%s' "$rc"
}

last_output() { # <file> <key>
  awk -F= -v key="$2" '$1 == key { value=substr($0, length(key) + 2) } END { print value }' "$1"
}

C1="$WORK/classifier-carried"
rc=$(run_classifier "$C1" 0 0 '{"carried":true,"source_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_time":"2026-09-27T00:00:00Z"}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C1/output" needs_review)" = false ] \
   && [ "$(last_output "$C1/output" classification)" = carried-forward ]; then
  pass "successful carry-forward publishes a reconcilable classification"
else
  fail "successful carry-forward left contradictory outputs (rc=$rc output=$(cat "$C1/output" 2>/dev/null) err=$(cat "$C1/err"))"
fi

C2="$WORK/classifier-carry-failed"
rc=$(run_classifier "$C2" 0 9 '{}')
if [ "$rc" -eq 0 ] \
   && [ "$(last_output "$C2/output" needs_review)" = true ] \
   && [ "$(last_output "$C2/output" classification)" = external-required ]; then
  pass "a failed carry-forward remains external-required"
else
  fail "failed carry-forward weakened fail-closed classification (rc=$rc output=$(cat "$C2/output" 2>/dev/null) err=$(cat "$C2/err"))"
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

RECONCILE_IF=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Reconcile a policy-owned fail-closed label") | .if' "$WORKFLOW")
if [[ "$RECONCILE_IF" == *"under-threshold"* ]] && [[ "$RECONCILE_IF" == *"carried-forward"* ]]; then
  pass "reconciliation accepts ordinary and carried-forward no-review classifications"
else
  fail "reconciliation condition excludes a no-review classification: $RECONCILE_IF"
fi

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_reconcile_fixture() { # <dir> <latest actor> <comment time> [event]
  local dir=$1 actor=$2 comment_time=$3 event=${4:-labeled}
  mkdir -p "$dir"
  cat >"$dir/live.json" <<JSON
{"head":{"sha":"$HEAD40"},"labels":[{"name":"needs-external-review"}]}
JSON
  cat >"$dir/timeline.json" <<JSON
[{"id":91,"event":"$event","label":{"name":"needs-external-review"},"actor":{"login":"$actor"},"created_at":"2026-09-25T01:36:05Z","commit_id":"$HEAD40"}]
JSON
  cat >"$dir/comments.json" <<JSON
[{"id":92,"user":{"login":"github-actions[bot]"},"created_at":"$comment_time","body":"**External Review Required**\\n- Could not fetch PR files; requiring review fail-closed"}]
JSON
}

run_reconcile() { # <fixture-dir>
  local dir=$1 rc=0
  env PATH="$WORK/bin:$PATH" REAL_BASH="$REAL_BASH" GH_STUB_DIR="$dir" \
    GH_TOKEN=fake-read LABEL_REMOVAL_TOKEN="${LABEL_REMOVAL_TOKEN_OVERRIDE-fake-write}" \
    PR_NUMBER=42 EXPECTED_HEAD_SHA="$HEAD40" REPO=o/r \
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
{"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"labels":[{"name":"needs-external-review"}]}
JSON
rc=$(run_reconcile "$R4")
if [ "$rc" -eq 0 ] && [ ! -f "$R4/deletes" ]; then
  pass "a head move preserves the label without failing successful classification (#1321)"
else
  fail "head move did not hold reconciliation (rc=$rc)"
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
jq '.[] .body = "<!-- mergepath-external-review-label:v1 head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cause=fail-closed -->\\n**External Review Required**\\n- read failed; requiring review fail-closed"' \
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
jq --arg head "$HEAD40" '.[] .body = "<!-- mergepath-external-review-label:v1 head=\($head) cause=fail-closed -->\\n**External Review Required**\\n- read failed; requiring review fail-closed"' \
  "$R9/comments.json" >"$R9/comments.tmp"
mv "$R9/comments.tmp" "$R9/comments.json"
rc=$(run_reconcile "$R9")
if [ "$rc" -eq 0 ] && [ "$(cat "$R9/deletes" 2>/dev/null)" = deleted ]; then
  pass "a provenance marker matching the classified PR head can authorize removal (#1321)"
else
  fail "matching provenance marker did not authorize safe removal (rc=$rc)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
