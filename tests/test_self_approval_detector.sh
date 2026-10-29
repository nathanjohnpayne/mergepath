#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/self-approval-detector.cjs"
RENDERER="$ROOT/scripts/render-self-approval-bootstrap.cjs"
WORKFLOW="$ROOT/.github/workflows/agent-review.yml"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available" >&2
  exit 0
fi

BOOTSTRAP_MODULE="$(mktemp "${TMPDIR:-/tmp}/self-approval-bootstrap.XXXXXX.cjs")"
DISMISS_MODULE="$(mktemp "${TMPDIR:-/tmp}/dismiss-review-fail-closed.XXXXXX.cjs")"
PROTECTION_MODULE="$(mktemp "${TMPDIR:-/tmp}/durable-approval-protection.XXXXXX.cjs")"
SNAPSHOT_MODULE="$(mktemp "${TMPDIR:-/tmp}/stable-review-snapshot.XXXXXX.cjs")"
TRIAGE_POLICY_MODULE="$(mktemp "${TMPDIR:-/tmp}/triage-policy-materialization.XXXXXX.cjs")"
APPROVAL_PHASE4_MODULE="$(mktemp "${TMPDIR:-/tmp}/approval-phase4-decision.XXXXXX.cjs")"
TRIAGE_IO_MODULE="$(mktemp "${TMPDIR:-/tmp}/triage-event-loop-io.XXXXXX.cjs")"
RENDER_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/self-approval-renderer.XXXXXX")"
TRIAGE_STEP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/triage-step.XXXXXX")"
trap 'rm -f "$BOOTSTRAP_MODULE" "$DISMISS_MODULE" "$PROTECTION_MODULE" "$SNAPSHOT_MODULE" "$TRIAGE_POLICY_MODULE" "$APPROVAL_PHASE4_MODULE" "$TRIAGE_IO_MODULE"; rm -rf "$RENDER_FIXTURE" "$TRIAGE_STEP_TMP"' EXIT

# JavaScript replacement strings interpret $&, $`, $', $1, $<name>, and $$.
# Canonical detector source is arbitrary text, so the renderer must preserve
# every such sequence byte-for-byte in both generated workflow mirrors.
mkdir -p "$RENDER_FIXTURE/scripts/workflow" "$RENDER_FIXTURE/.github/workflows"
cp "$DETECTOR" "$RENDER_FIXTURE/scripts/self-approval-detector.cjs"
cp "$ROOT/scripts/workflow/approval-triage.cjs" "$RENDER_FIXTURE/scripts/workflow/approval-triage.cjs"
cp "$ROOT/scripts/workflow/review-triage.cjs" "$RENDER_FIXTURE/scripts/workflow/review-triage.cjs"
cp "$RENDERER" "$RENDER_FIXTURE/scripts/render-self-approval-bootstrap.cjs"
cp "$WORKFLOW" "$RENDER_FIXTURE/.github/workflows/agent-review.yml"
RENDER_DETECTOR="$RENDER_FIXTURE/scripts/self-approval-detector.cjs" node <<'NODE'
const fs = require('fs');
const file = process.env.RENDER_DETECTOR;
let source = fs.readFileSync(file, 'utf8');
source = source.replace(
  '// BEGIN SELF-APPROVAL DETECTOR IMPLEMENTATION',
  () => "// BEGIN SELF-APPROVAL DETECTOR IMPLEMENTATION\n// detector-replacement-sentinel:$&|$`|$'|$1|$<name>|$$",
);
source = source.replace(
  '// BEGIN STABLE PR LABEL NAMES',
  () => "// BEGIN STABLE PR LABEL NAMES\n// label-replacement-sentinel:$&|$`|$'|$1|$<name>|$$",
);
fs.writeFileSync(file, source);
NODE
if ! node "$RENDER_FIXTURE/scripts/render-self-approval-bootstrap.cjs" --write \
     >"$RENDER_FIXTURE/write.out" 2>"$RENDER_FIXTURE/write.err" \
   || [ "$(grep -Fc 'detector-replacement-sentinel:$&|$`|$'"'"'|$1|$<name>|$$' "$RENDER_FIXTURE/.github/workflows/agent-review.yml")" -ne 1 ] \
   || [ "$(grep -Fc 'label-replacement-sentinel:$&|$`|$'"'"'|$1|$<name>|$$' "$RENDER_FIXTURE/.github/workflows/agent-review.yml")" -ne 2 ] \
   || ! node "$RENDER_FIXTURE/scripts/render-self-approval-bootstrap.cjs" --check \
        >"$RENDER_FIXTURE/check.out" 2>"$RENDER_FIXTURE/check.err"; then
  echo "FAIL: renderer did not preserve JavaScript replacement tokens byte-for-byte" >&2
  cat "$RENDER_FIXTURE/write.err" "$RENDER_FIXTURE/check.err" >&2
  exit 1
fi

# A mixed-CRLF approval block must be replaced exactly, even if the other
# blocks also change and would make an aggregate write appear successful.
RENDER_WORKFLOW="$RENDER_FIXTURE/.github/workflows/agent-review.yml" \
RENDER_APPROVAL="$RENDER_FIXTURE/scripts/workflow/approval-triage.cjs" node <<'NODE'
const fs = require('fs');
const file = process.env.RENDER_WORKFLOW;
let workflow = fs.readFileSync(file, 'utf8');
const begin = workflow.indexOf('            // BEGIN TRIAGE READ BOOTSTRAP');
const endMarker = '            // END TRIAGE READ BOOTSTRAP';
const end = workflow.indexOf(endMarker, begin) + endMarker.length;
workflow = workflow.slice(0, begin) + workflow.slice(begin, end).replace(/\n/g, '\r\n') + workflow.slice(end);
fs.writeFileSync(file, workflow);
const helper = process.env.RENDER_APPROVAL;
fs.writeFileSync(helper, fs.readFileSync(helper, 'utf8').replace(
  '// BEGIN APPROVAL TRIAGE IMPLEMENTATION',
  '// BEGIN APPROVAL TRIAGE IMPLEMENTATION\n// mixed-line-ending replacement regression'));
NODE
node "$RENDER_FIXTURE/scripts/render-self-approval-bootstrap.cjs" --write >/dev/null
node "$RENDER_FIXTURE/scripts/render-self-approval-bootstrap.cjs" --check >/dev/null
awk '
  /BEGIN SELF-APPROVAL BOOTSTRAP/ { capture=1; next }
  /END SELF-APPROVAL BOOTSTRAP/   { capture=0 }
  /BEGIN SELF-APPROVAL RESOLVER/  { capture=1; next }
  /END SELF-APPROVAL RESOLVER/    { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" > "$BOOTSTRAP_MODULE"
if [ ! -s "$BOOTSTRAP_MODULE" ]; then
  echo "FAIL: could not extract the first-rollout bootstrap detector from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { bootstrapDetector, detectorSupportsDurableFallback, selectDetector };\n' >> "$BOOTSTRAP_MODULE"

awk '
  /BEGIN DISMISS REVIEW FAIL-CLOSED/ { capture=1; next }
  /END DISMISS REVIEW FAIL-CLOSED/   { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" > "$DISMISS_MODULE"
if [ ! -s "$DISMISS_MODULE" ]; then
  echo "FAIL: could not extract the workflow dismissal helper from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { dismissReviewFailClosed };\n' >> "$DISMISS_MODULE"

awk '
  /BEGIN DURABLE APPROVAL PROTECTION/ { capture=1; next }
  /END DURABLE APPROVAL PROTECTION/   { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" > "$PROTECTION_MODULE"
if [ ! -s "$PROTECTION_MODULE" ]; then
  echo "FAIL: could not extract the durable approval protection helper from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { registeredReviewerUnion, protectDurableApproval };\n' >> "$PROTECTION_MODULE"

awk '
  /BEGIN STABLE REVIEW SNAPSHOT/ { capture=1; next }
  /END STABLE REVIEW SNAPSHOT/   { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" > "$SNAPSHOT_MODULE"
if [ ! -s "$SNAPSHOT_MODULE" ]; then
  echo "FAIL: could not extract the stable review snapshot helper from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { readStableReviewSnapshot };\n' >> "$SNAPSHOT_MODULE"

awk '
  /BEGIN STABLE PR LABEL NAMES/ { capture=1; next }
  /END STABLE PR LABEL NAMES/   { capture=0 }
  capture { print }
' "$DETECTOR" > "$APPROVAL_PHASE4_MODULE"
awk '
  /BEGIN APPROVAL PHASE 4 DECISION/ { capture=1; next }
  /END APPROVAL PHASE 4 DECISION/   { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" >> "$APPROVAL_PHASE4_MODULE"
if [ ! -s "$APPROVAL_PHASE4_MODULE" ]; then
  echo "FAIL: could not extract the live approval Phase 4 decision from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { stablePrLabelNames, approvalEnforcementSnapshot, phase4RequiredForApprovalGuard };\n' >> "$APPROVAL_PHASE4_MODULE"

awk '
  /BEGIN TRIAGE POLICY MATERIALIZATION DECISION/ { capture=1; next }
  /END TRIAGE POLICY MATERIALIZATION DECISION/   { capture=0 }
  /BEGIN TRIAGE PHASE 4 DECISION/ { capture=1; next }
  /END TRIAGE PHASE 4 DECISION/   { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" > "$TRIAGE_POLICY_MODULE"
if [ ! -s "$TRIAGE_POLICY_MODULE" ]; then
  echo "FAIL: could not extract the triage policy materialization decision from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { shouldMaterializeDefaultPolicy, stablePrLabelNames, phase4IntrinsicRequiredForTriage, phase4RequiredForTriage, triageMayMutateLabels };\n' >> "$TRIAGE_POLICY_MODULE"

TRIAGE_POLICY_PATH="$TRIAGE_POLICY_MODULE" node <<'NODE'
const {
  shouldMaterializeDefaultPolicy,
  stablePrLabelNames,
  phase4IntrinsicRequiredForTriage,
  phase4RequiredForTriage,
  triageMayMutateLabels,
} = require(process.env.TRIAGE_POLICY_PATH);
const base = {
  baseRef: 'main',
  baseSha: 'base-current',
  defaultBranch: 'main',
};
const cases = [
  ['equal trusted checkout', {...base, checkoutSha: 'base-current'}, false],
  ['checkout behind live base', {...base, checkoutSha: 'base-older'}, true],
  ['checkout ahead of live base', {...base, checkoutSha: 'base-newer'}, true],
  ['unprovable checkout', {...base, checkoutSha: ''}, true],
  ['non-default exact-base fetch', {
    ...base,
    baseRef: 'release/1.x',
    checkoutSha: 'main-any',
  }, false],
];
for (const [name, input, expected] of cases) {
  const actual = shouldMaterializeDefaultPolicy(input);
  if (actual !== expected) {
    throw new Error(`${name}: expected ${expected}, got ${actual}`);
  }
}

const phase4Cases = [
  ['diff requires review', {
    requiresReview: true,
    laneVerifiedHead: false,
    pr: {labels: []},
  }, true],
  ['plain under-threshold PR', {
    requiresReview: false,
    laneVerifiedHead: false,
    pr: {labels: []},
  }, false],
  ['verified propagation lane', {
    requiresReview: true,
    laneVerifiedHead: true,
    pr: {labels: []},
  }, false],
  ['human force-on label under threshold', {
    requiresReview: false,
    laneVerifiedHead: false,
    pr: {labels: [{name: 'needs-external-review'}]},
  }, true],
  ['human force-on label outranks propagation exemption', {
    requiresReview: false,
    laneVerifiedHead: true,
    pr: {labels: [{name: 'documentation'}, {name: 'needs-external-review'}]},
  }, true],
];
for (const [name, input, expected] of phase4Cases) {
  const actual = phase4RequiredForTriage(input);
  if (actual !== expected) {
    throw new Error(`${name}: expected ${expected}, got ${actual}`);
  }
}

const intrinsicCases = [
  ['threshold or path requires review', {
    requiresReview: true,
    laneVerifiedHead: false,
  }, true],
  ['plain under-threshold PR', {
    requiresReview: false,
    laneVerifiedHead: false,
  }, false],
  ['verified propagation lane', {
    requiresReview: true,
    laneVerifiedHead: true,
  }, false],
];
for (const [name, input, expected] of intrinsicCases) {
  const actual = phase4IntrinsicRequiredForTriage(input);
  if (actual !== expected) {
    throw new Error(`${name}: expected ${expected}, got ${actual}`);
  }
}

const sorted = stablePrLabelNames({
  labels: [{name: 'zeta'}, {name: 'needs-external-review'}, {name: 'alpha'}],
});
if (JSON.stringify(sorted) !== JSON.stringify(['alpha', 'needs-external-review', 'zeta'])) {
  throw new Error(`stable label snapshot is not sorted: ${JSON.stringify(sorted)}`);
}
for (const malformed of [
  {},
  {labels: null},
  {labels: {}},
  {labels: [{name: ''}]},
  {labels: [{}]},
]) {
  let threw = false;
  try {
    stablePrLabelNames(malformed);
  } catch (_) {
    threw = true;
  }
  if (!threw) {
    throw new Error(`malformed live labels did not fail closed: ${JSON.stringify(malformed)}`);
  }
}

const mutationCases = [
  ['force-on label addition is classification-only', {
    eventName: 'pull_request',
    action: 'labeled',
    labelName: 'needs-external-review',
  }, false],
  ['unrelated label addition remains outside classification-only mode', {
    eventName: 'pull_request',
    action: 'labeled',
    labelName: 'documentation',
  }, true],
  ['blocking-label removal is classification-only', {
    eventName: 'pull_request',
    action: 'unlabeled',
    labelName: 'human-hold',
  }, false],
  ['synchronize may refresh a required label', {
    eventName: 'pull_request',
    action: 'synchronize',
    labelName: undefined,
  }, true],
  ['approved review may refresh a required label', {
    eventName: 'pull_request_review',
    action: 'submitted',
    labelName: undefined,
  }, true],
];
for (const [name, input, expected] of mutationCases) {
  const actual = triageMayMutateLabels(input);
  if (actual !== expected) {
    throw new Error(`${name}: expected ${expected}, got ${actual}`);
  }
}
NODE

APPROVAL_PHASE4_PATH="$APPROVAL_PHASE4_MODULE" DETECTOR_PATH="$DETECTOR" node <<'NODE'
const {
  stablePrLabelNames,
  approvalEnforcementSnapshot,
  phase4RequiredForApprovalGuard,
} = require(process.env.APPROVAL_PHASE4_PATH);
const {decide} = require(process.env.DETECTOR_PATH);

const unlabeled = {
  head: {sha: 'head'},
  base: {ref: 'main', sha: 'base'},
  user: {login: 'nathanjohnpayne'},
  body: 'Authoring-Agent: codex',
  labels: [],
};
const labeled = {
  ...unlabeled,
  labels: [{name: 'documentation'}, {name: 'needs-external-review'}],
};
const policySnapshot = pr => JSON.stringify({
  head: pr.head.sha,
  baseRef: pr.base.ref,
  baseSha: pr.base.sha,
});

if (phase4RequiredForApprovalGuard('false', unlabeled)) {
  throw new Error('plain under-threshold live PR became Phase 4');
}
if (!phase4RequiredForApprovalGuard('true', unlabeled)) {
  throw new Error('triage-required Phase 4 was lost');
}
if (!phase4RequiredForApprovalGuard('false', labeled)) {
  throw new Error('live force-on label did not override stale Phase 3 triage');
}
if (
  approvalEnforcementSnapshot(unlabeled, policySnapshot) ===
  approvalEnforcementSnapshot(labeled, policySnapshot)
) {
  throw new Error('approval snapshot omitted live label state');
}
if (JSON.stringify(stablePrLabelNames(labeled)) !==
    JSON.stringify(['documentation', 'needs-external-review'])) {
  throw new Error('approval label snapshot is not stable and sorted');
}

const decision = decide({
  prAuthor: 'nathanjohnpayne',
  authorIdentity: 'nathanjohnpayne',
  prBody: labeled.body,
  reviewer: 'nathanpayne-codex',
  reviewerAccounts: ['nathanpayne-codex', 'nathanpayne-cursor'],
  requiresExternalReview: phase4RequiredForApprovalGuard('false', labeled),
});
if (decision.action !== 'block' || decision.reason !== 'same-agent-phase-4-approval') {
  throw new Error(`force-on labeled event did not invalidate the standing same-agent approval: ${JSON.stringify(decision)}`);
}

for (const malformed of [{}, {labels: null}, {labels: [{}]}]) {
  let threw = false;
  try {
    phase4RequiredForApprovalGuard('false', malformed);
  } catch (_) {
    threw = true;
  }
  if (!threw) {
    throw new Error(`malformed live approval labels did not fail closed: ${JSON.stringify(malformed)}`);
  }
}
NODE

DETECTOR_PATH="$DETECTOR" BOOTSTRAP_PATH="$BOOTSTRAP_MODULE" node <<'NODE'
const canonical = require(process.env.DETECTOR_PATH);
const {
  bootstrapDetector,
  detectorSupportsDurableFallback,
  selectDetector,
} = require(process.env.BOOTSTRAP_PATH);
const implementations = [
  ['canonical', canonical],
  ['bootstrap', bootstrapDetector()],
];
for (const [implementationName, implementation] of implementations) {
  if (!detectorSupportsDurableFallback(implementation)) {
    throw new Error(`${implementationName}: complete detector capability was rejected`);
  }
}

const reviewerAccounts = [
  'nathanpayne-claude',
  'nathanpayne-codex',
  'nathanpayne-cursor',
];
const shared = {
  prAuthor: 'nathanjohnpayne',
  authorIdentity: 'nathanjohnpayne',
  prBody: '',
  reviewerAccounts,
};

const cases = [
  ['same-agent Phase 4', {...shared, reviewer: 'nathanpayne-codex', prBody: 'Authoring-Agent: codex', requiresExternalReview: true}, 'block', 'same-agent-phase-4-approval'],
  ['different-agent Phase 4', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: CoDeX', requiresExternalReview: true}, 'allow', 'different-agent-phase-4-approval'],
  ['CRLF declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\r\n\r\n## Self-Review', requiresExternalReview: true}, 'allow', 'different-agent-phase-4-approval'],
  ['under-threshold same agent', {...shared, reviewer: 'nathanpayne-codex', requiresExternalReview: false}, 'allow', 'under-threshold-agent-approval'],
  ['native-account self-approval', {...shared, prAuthor: 'nathanpayne-codex', reviewer: 'NATHANPAYNE-CODEX', requiresExternalReview: false}, 'block', 'same-native-account-approval'],
  ['human tiebreaker', {...shared, reviewer: 'nathanpayne', requiresExternalReview: true}, 'allow', 'human-or-unregistered-reviewer'],
  ['unknown applicability', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex'}, 'block', 'indeterminate-review-requirement'],
  ['missing declaration', {...shared, reviewer: 'nathanpayne-cursor', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'missing-authoring-agent-declaration'],
  ['unknown declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: unregistered', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'unknown-authoring-agent'],
  ['duplicate declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\nAuthoring-Agent: codex', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'multiple-authoring-agent-declarations'],
  ['conflicting declarations', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\nAuthoring-Agent: cursor', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'multiple-authoring-agent-declarations'],
  ['valid plus malformed declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\nAuthoring-Agent: cursor extra', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'multiple-authoring-agent-declarations'],
  ['valid plus indented declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\n Authoring-Agent: cursor', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'multiple-authoring-agent-declarations'],
  ['valid plus placeholder declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\nAuthoring-Agent: <agent>', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'multiple-authoring-agent-declarations'],
  ['valid plus empty declaration', {...shared, reviewer: 'nathanpayne-cursor', prBody: 'Authoring-Agent: codex\nAuthoring-Agent:', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'multiple-authoring-agent-declarations'],
  ['ambiguous reviewer mapping', {...shared, reviewer: 'nathanpayne-cursor', reviewerAccounts: ['nathanpayne-codex', 'nathanpayne-special-codex', 'nathanpayne-cursor'], prBody: 'Authoring-Agent: codex', requiresExternalReview: true}, 'block', 'indeterminate-phase-4-author', 'ambiguous-authoring-agent-mapping'],
  ['missing PR author', {...shared, prAuthor: '', reviewer: 'nathanpayne-codex', requiresExternalReview: false}, 'block', 'indeterminate-native-author'],
  ['missing shared author', {...shared, authorIdentity: '', reviewer: 'nathanpayne-codex', requiresExternalReview: false}, 'block', 'indeterminate-native-author'],
  ['Dependabot author', {...shared, prAuthor: 'dependabot[bot]', reviewer: 'nathanpayne-codex', requiresExternalReview: true}, 'allow', 'non-shared-author-pr'],
  ['external contributor', {...shared, prAuthor: 'outside-contributor', reviewer: 'nathanpayne-codex', requiresExternalReview: true}, 'allow', 'non-shared-author-pr'],
];

for (const body of [
  ' Authoring-Agent: codex',
  'Authoring-Agent:',
  'Authoring-Agent: codex extra',
  'Authoring-Agent: <agent>',
]) {
  cases.push([
    `malformed declaration ${JSON.stringify(body)}`,
    {...shared, reviewer: 'nathanpayne-cursor', prBody: body, requiresExternalReview: true},
    'block',
    'indeterminate-phase-4-author',
    'malformed-authoring-agent-declaration',
  ]);
}

for (const [implementationName, { decide }] of implementations) {
  for (const [name, input, expectedAction, expectedReason, expectedDetail] of cases) {
    const actual = decide(input);
    const expectedPersistentViolation =
      expectedReason === 'same-native-account-approval';
    if (
      actual.action !== expectedAction ||
      actual.reason !== expectedReason ||
      actual.detail !== expectedDetail ||
      Boolean(actual.persistentViolation) !== expectedPersistentViolation
    ) {
      throw new Error(
        `${implementationName}/${name}: expected ${expectedAction}/${expectedReason}/${expectedDetail}/persistent=${expectedPersistentViolation}, got ${JSON.stringify(actual)}`,
      );
    }
  }
}

const repaired = {
  ...shared,
  reviewer: 'nathanpayne-cursor',
  requiresExternalReview: true,
};
for (const [implementationName, { decide }] of implementations) {
  const invalid = decide({...repaired, prBody: 'Authoring-Agent:'});
  const fixed = decide({...repaired, prBody: 'Authoring-Agent: codex'});
  if (invalid.action !== 'block' || invalid.persistentViolation || fixed.action !== 'allow') {
    throw new Error(`${implementationName}: declaration repair is not recoverable: ${JSON.stringify({invalid, fixed})}`);
  }
}

const reviews = [
  {id: 1, user: {login: 'nathanpayne-codex'}, state: 'APPROVED', submitted_at: '2026-01-01T00:00:00Z'},
  {id: 2, user: {login: 'nathanpayne-codex'}, state: 'COMMENTED', submitted_at: '2026-01-02T00:00:00Z'},
  {id: 3, user: {login: 'nathanpayne-cursor'}, state: 'APPROVED', submitted_at: '2026-01-01T00:00:00Z'},
  {id: 4, user: {login: 'nathanpayne-cursor'}, state: 'CHANGES_REQUESTED', submitted_at: '2026-01-03T00:00:00Z'},
  {id: 5, user: {login: 'nathanpayne-claude'}, state: 'APPROVED', submitted_at: '2026-01-04T00:00:00Z'},
  {id: 6, user: {login: 'outside-reviewer'}, state: 'APPROVED', submitted_at: '2026-01-05T00:00:00Z'},
  {id: 7, user: {login: 'nathanjohnpayne'}, state: 'APPROVED', submitted_at: '2026-01-06T00:00:00Z'},
];

for (const [implementationName, { decide, latestApprovedReviews }] of implementations) {
  if (typeof latestApprovedReviews !== 'function') {
    throw new Error(`${implementationName}: latestApprovedReviews is unavailable`);
  }
  const latest = latestApprovedReviews({reviews, reviewerAccounts, prAuthor: shared.prAuthor});
  const logins = latest.map(review => review.user.login).sort();
  const expected = ['nathanpayne-claude', 'nathanpayne-codex'];
  if (JSON.stringify(logins) !== JSON.stringify(expected)) {
    throw new Error(`${implementationName}: latest approval collapse mismatch: ${JSON.stringify(logins)}`);
  }

  const decisions = latest.map(review => decide({
    ...shared,
    reviewer: review.user.login,
    prBody: 'Authoring-Agent: codex',
    requiresExternalReview: true,
  }));
  if (
    decisions.filter(decision => decision.action === 'block').length !== 1 ||
    decisions.filter(decision => decision.action === 'allow').length !== 1
  ) {
    throw new Error(`${implementationName}: mixed same/different approvals were not classified independently: ${JSON.stringify(decisions)}`);
  }

  const phase3 = decide({
    ...shared,
    reviewer: 'nathanpayne-codex',
    prBody: 'Authoring-Agent: codex',
    requiresExternalReview: false,
  });
  const phase4 = decide({
    ...shared,
    reviewer: 'nathanpayne-codex',
    prBody: 'Authoring-Agent: codex',
    requiresExternalReview: true,
  });
  if (phase3.action !== 'allow' || phase4.action !== 'block') {
    throw new Error(`${implementationName}: persisted approval transition was not reproduced: ${JSON.stringify({phase3, phase4})}`);
  }

  const beforeEdit = decide({
    ...shared,
    reviewer: 'nathanpayne-claude',
    prBody: 'Authoring-Agent: codex',
    requiresExternalReview: true,
  });
  const afterEdit = decide({
    ...shared,
    reviewer: 'nathanpayne-claude',
    prBody: 'Authoring-Agent: claude',
    requiresExternalReview: true,
  });
  if (beforeEdit.action !== 'allow' || afterEdit.action !== 'block') {
    throw new Error(`${implementationName}: PR-body edit did not invalidate the carried approval: ${JSON.stringify({beforeEdit, afterEdit})}`);
  }
}

// #1094 cancellation ordering: every direct approval event has a durable,
// review-ID-specific run and must enforce the complete standing set. A later
// independent approval cannot cancel the earlier same-agent run; each run uses
// only its own webhook as a missing-ID fallback while classifying all live
// standing approvals.
for (const [implementationName, implementation] of implementations) {
  const {
    reviewsWithDirectFallback,
    prepareDirectApproval,
    planApprovalEnforcement,
  } = implementation;
  if (
    typeof reviewsWithDirectFallback !== 'function' ||
    typeof prepareDirectApproval !== 'function' ||
    typeof planApprovalEnforcement !== 'function'
  ) {
    throw new Error(`${implementationName}: direct-event enforcement helpers are unavailable`);
  }

  const sameAgent = {
    id: 101,
    user: {login: 'nathanpayne-codex'},
    state: 'APPROVED',
    commit_id: 'old-head',
    submitted_at: '2026-01-08T00:00:00Z',
  };
  const independent = {
    id: 102,
    user: {login: 'nathanpayne-cursor'},
    state: 'APPROVED',
    commit_id: 'old-head',
    submitted_at: '2026-01-08T00:00:01Z',
  };
  const approvalInput = {
    ...shared,
    prBody: 'Authoring-Agent: codex',
    requiresExternalReview: true,
  };

  const replacementRun = planApprovalEnforcement({
    ...approvalInput,
    reviews: reviewsWithDirectFallback([sameAgent, independent], independent),
    directReviewId: independent.id,
  });
  if (
    !replacementRun.eligibleApproval ||
    replacementRun.persistentDirectViolation ||
    replacementRun.directBlockedDiagnostics.length !== 0 ||
    replacementRun.blockedDiagnostics.length !== 1 ||
    replacementRun.approvals.find(item => item.review.id === sameAgent.id)?.decision.action !== 'block' ||
    replacementRun.approvals.find(item => item.review.id === independent.id)?.decision.action !== 'allow'
  ) {
    throw new Error(`${implementationName}: replacement direct approval did not enforce the carried blocker: ${JSON.stringify(replacementRun)}`);
  }

  const violatingRun = planApprovalEnforcement({
    ...approvalInput,
    reviews: [sameAgent, independent],
    directReviewId: sameAgent.id,
  });
  if (
    !violatingRun.eligibleApproval ||
    violatingRun.persistentDirectViolation ||
    violatingRun.directBlockedDiagnostics.length !== 1
  ) {
    throw new Error(`${implementationName}: mutable same-agent violation did not remain dismiss-only: ${JSON.stringify(violatingRun)}`);
  }

  const nativeAccountApproval = {
    id: 103,
    user: {login: 'nathanpayne-codex'},
    state: 'APPROVED',
    submitted_at: '2026-01-08T00:00:02Z',
  };
  const nativeAccountRun = planApprovalEnforcement({
    ...approvalInput,
    prAuthor: 'nathanpayne-codex',
    reviews: [nativeAccountApproval],
    directReviewId: nativeAccountApproval.id,
  });
  if (
    nativeAccountRun.eligibleApproval ||
    !nativeAccountRun.persistentDirectViolation ||
    nativeAccountRun.directBlockedDiagnostics.length !== 1 ||
    nativeAccountRun.approvals[0]?.decision.reason !== 'same-native-account-approval'
  ) {
    throw new Error(`${implementationName}: native-account direct approval bypassed enforcement: ${JSON.stringify(nativeAccountRun)}`);
  }

  const dismissedLive = {...independent, state: 'DISMISSED'};
  const liveWins = reviewsWithDirectFallback([dismissedLive], independent);
  const dismissedPlan = planApprovalEnforcement({
    ...approvalInput,
    reviews: liveWins,
    directReviewId: independent.id,
  });
  if (
    liveWins.length !== 1 ||
    liveWins[0].state !== 'DISMISSED' ||
    dismissedPlan.approvals.length !== 0 ||
    dismissedPlan.eligibleApproval
  ) {
    throw new Error(`${implementationName}: stale APPROVED webhook overrode the live dismissed state: ${JSON.stringify({liveWins, dismissedPlan})}`);
  }

  const laggingApi = reviewsWithDirectFallback([sameAgent], independent);
  if (laggingApi.length !== 2 || !laggingApi.some(review => review.id === independent.id)) {
    throw new Error(`${implementationName}: eventual-consistency fallback lost the direct approval`);
  }

  const emptyLaggingApi = reviewsWithDirectFallback([], independent);
  const emptyLaggingPlan = planApprovalEnforcement({
    ...approvalInput,
    reviews: emptyLaggingApi,
    directReviewId: independent.id,
  });
  if (
    emptyLaggingApi.length !== 1 ||
    emptyLaggingApi[0]?.id !== independent.id ||
    !emptyLaggingPlan.eligibleApproval ||
    emptyLaggingPlan.persistentDirectViolation
  ) {
    throw new Error(`${implementationName}: an empty lagging reviews API lost the durable webhook's own approval: ${JSON.stringify({emptyLaggingApi, emptyLaggingPlan})}`);
  }

  const emptyBlockingApi = reviewsWithDirectFallback([], sameAgent);
  const emptyBlockingPlan = planApprovalEnforcement({
    ...approvalInput,
    reviews: emptyBlockingApi,
    directReviewId: sameAgent.id,
  });
  if (
    emptyBlockingApi.length !== 1 ||
    emptyBlockingPlan.eligibleApproval ||
    emptyBlockingPlan.persistentDirectViolation ||
    emptyBlockingPlan.directBlockedDiagnostics.length !== 1
  ) {
    throw new Error(`${implementationName}: an empty lagging reviews API lost the durable webhook's dismiss-only block: ${JSON.stringify({emptyBlockingApi, emptyBlockingPlan})}`);
  }

  const stalePrepared = prepareDirectApproval({
    liveReviews: [],
    directReview: sameAgent,
    eventEnforcementCurrent: false,
    liveHeadSha: 'new-head',
  });
  const transitionedPlan = planApprovalEnforcement({
    ...approvalInput,
    reviews: stalePrepared.reviews,
    directReviewId: sameAgent.id,
    directAttributionCurrent: stalePrepared.directAttributionCurrent,
  });
  if (
    stalePrepared.reviews.length !== 1 ||
    stalePrepared.reviews[0]?.id !== sameAgent.id ||
    stalePrepared.directAttributionCurrent ||
    transitionedPlan.eligibleApproval ||
    transitionedPlan.persistentDirectViolation ||
    transitionedPlan.directBlockedDiagnostics.length !== 0 ||
    transitionedPlan.blockedDiagnostics.length !== 1
  ) {
    throw new Error(`${implementationName}: a stale direct webhook retained persistent attribution after live PR transition: ${JSON.stringify(transitionedPlan)}`);
  }
}

if (typeof canonical.evaluateLatestApprovals !== 'function') {
  throw new Error('canonical detector does not expose final live approval evaluation');
}

const liveReviews = [
  {id: 20, user: {login: 'nathanpayne-codex'}, state: 'APPROVED', commit_id: 'head123', submitted_at: '2026-01-07T00:00:00Z'},
];
const beforeLiveEdit = canonical.evaluateLatestApprovals({
  ...shared,
  reviews: liveReviews,
  headSha: 'head123',
  requireHead: true,
  prBody: 'Authoring-Agent: claude',
  requiresExternalReview: true,
});
const afterLiveEdit = canonical.evaluateLatestApprovals({
  ...shared,
  reviews: liveReviews,
  headSha: 'head123',
  requireHead: true,
  prBody: 'Authoring-Agent: codex',
  requiresExternalReview: true,
});
if (!beforeLiveEdit.eligibleApproval || afterLiveEdit.eligibleApproval) {
  throw new Error(`live PR-body edit did not revoke the final approval decision: ${JSON.stringify({beforeLiveEdit, afterLiveEdit})}`);
}

const staleHead = canonical.evaluateLatestApprovals({
  ...shared,
  reviews: liveReviews,
  headSha: 'new-head',
  requireHead: true,
  prBody: 'Authoring-Agent: claude',
  requiresExternalReview: true,
});
if (staleHead.eligibleApproval || staleHead.approvals.length !== 0) {
  throw new Error(`stale-head approval survived the final exact-head filter: ${JSON.stringify(staleHead)}`);
}

const canonicalSentinel = {
  name: 'canonical',
  stablePrLabelNames() {},
  decide() {},
  latestApprovedReviews() {},
  reviewsWithDirectFallback() {},
  prepareDirectApproval() {},
  planApprovalEnforcement() {},
};
const bootstrapSentinel = {name: 'bootstrap'};
let canonicalLoads = 0;
let bootstrapLoads = 0;
const modulePresent = selectDetector({
  modulePresent: true,
  trustedWorkflow: 'SELF_APPROVAL_DETECTOR_DURABLE_FALLBACK_V2',
  loadCanonical: () => {
    canonicalLoads += 1;
    return canonicalSentinel;
  },
  loadBootstrap: () => {
    bootstrapLoads += 1;
    return bootstrapSentinel;
  },
});
if (modulePresent !== canonicalSentinel || canonicalLoads !== 1 || bootstrapLoads !== 0) {
  throw new Error('module-present resolver did not select only the canonical detector');
}

const oldCanonical = {
  decide() {},
  latestApprovedReviews() {},
  reviewsWithDirectFallback() {},
  prepareDirectApproval() {},
  planApprovalEnforcement() {},
};
if (detectorSupportsDurableFallback(oldCanonical)) {
  throw new Error('a canonical detector without stable label normalization was accepted');
}
const capabilitySkew = selectDetector({
  modulePresent: true,
  trustedWorkflow: 'name: Agent Review Pipeline\n# legacy workflow',
  loadCanonical: () => {
    canonicalLoads += 1;
    return oldCanonical;
  },
  loadBootstrap: () => {
    bootstrapLoads += 1;
    return bootstrapSentinel;
  },
});
if (capabilitySkew !== bootstrapSentinel || canonicalLoads !== 2 || bootstrapLoads !== 1) {
  throw new Error('present-but-pre-capability detector did not use the bounded bootstrap');
}

const legacyTrustedWorkflow = selectDetector({
  modulePresent: false,
  trustedWorkflow: 'name: Agent Review Pipeline\n# legacy workflow',
  loadCanonical: () => canonicalSentinel,
  loadBootstrap: () => {
    bootstrapLoads += 1;
    return bootstrapSentinel;
  },
});
if (legacyTrustedWorkflow !== bootstrapSentinel || bootstrapLoads !== 2) {
  throw new Error('legacy trusted workflow did not select the bounded bootstrap');
}

let markerMissingModuleFailed = false;
try {
  selectDetector({
    modulePresent: false,
    trustedWorkflow: 'SELF_APPROVAL_DETECTOR_DURABLE_FALLBACK_V2',
    loadCanonical: () => canonicalSentinel,
    loadBootstrap: () => bootstrapSentinel,
  });
} catch (error) {
  markerMissingModuleFailed = /requires the durable approval detector capability/.test(String(error));
}
if (!markerMissingModuleFailed) {
  throw new Error('marker-bearing trusted workflow with a missing module did not fail closed');
}

let markerIncompatibleModuleFailed = false;
try {
  selectDetector({
    modulePresent: true,
    trustedWorkflow: 'SELF_APPROVAL_DETECTOR_DURABLE_FALLBACK_V2',
    loadCanonical: () => oldCanonical,
    loadBootstrap: () => bootstrapSentinel,
  });
} catch (error) {
  markerIncompatibleModuleFailed = /missing or incompatible/.test(String(error));
}
if (!markerIncompatibleModuleFailed) {
  throw new Error('marker-bearing trusted workflow accepted an incompatible module');
}
NODE

DISMISS_PATH="$DISMISS_MODULE" \
  PROTECTION_PATH="$PROTECTION_MODULE" \
  SNAPSHOT_PATH="$SNAPSHOT_MODULE" \
  APPROVAL_PHASE4_PATH="$APPROVAL_PHASE4_MODULE" \
  DETECTOR_PATH="$DETECTOR" \
  node <<'NODE'
const {dismissReviewFailClosed} = require(process.env.DISMISS_PATH);
const {protectDurableApproval} = require(process.env.PROTECTION_PATH);
const {readStableReviewSnapshot} = require(process.env.SNAPSHOT_PATH);
const {
  approvalEnforcementSnapshot,
  phase4RequiredForApprovalGuard,
} = require(process.env.APPROVAL_PHASE4_PATH);
const {prepareDirectApproval} = require(process.env.DETECTOR_PATH);

async function expectOriginalWriteError(name, read) {
  const writeError = new Error(`${name}-write`);
  let noticeCount = 0;
  try {
    await dismissReviewFailClosed({
      reviewId: 701,
      dismiss: async () => { throw writeError; },
      read,
      notice: () => { noticeCount += 1; },
    });
  } catch (error) {
    if (error !== writeError || noticeCount !== 0) {
      throw new Error(`${name}: did not rethrow the original dismissal error`);
    }
    return;
  }
  throw new Error(`${name}: unsafe dismissal readback was accepted`);
}

async function main() {
  let notices = 0;
  const overlapped = await dismissReviewFailClosed({
    reviewId: 701,
    dismiss: async () => { throw new Error('overlap'); },
    read: async () => ({id: 701, state: 'DISMISSED'}),
    notice: () => { notices += 1; },
  });
  if (overlapped !== 'already-dismissed' || notices !== 1) {
    throw new Error('exact-ID DISMISSED overlap was not accepted');
  }

  await expectOriginalWriteError(
    'wrong-id',
    async () => ({id: 702, state: 'DISMISSED'}),
  );
  await expectOriginalWriteError(
    'still-approved',
    async () => ({id: 701, state: 'APPROVED'}),
  );
  await expectOriginalWriteError(
    'read-failure',
    async () => { throw new Error('read failed'); },
  );

  const directReview = {
    id: 801,
    state: 'APPROVED',
    commit_id: 'old-head',
    user: {login: 'nathanpayne-codex'},
  };
  let protectiveDismissals = 0;
  const protectedApproval = await protectDurableApproval({
    directReview,
    reviewerLists: ['not-json', '["nathanpayne-codex"]'],
    dismiss: async approval => {
      if (approval !== directReview) {
        throw new Error('protective dismissal lost exact webhook object');
      }
      protectiveDismissals += 1;
    },
  });
  if (!protectedApproval || protectiveDismissals !== 1) {
    throw new Error('registered durable approval was not protected on uncertainty');
  }
  const humanProtected = await protectDurableApproval({
    directReview: {...directReview, user: {login: 'human-reviewer'}},
    reviewerLists: ['["nathanpayne-codex"]'],
    dismiss: async () => { protectiveDismissals += 1; },
  });
  if (humanProtected || protectiveDismissals !== 1) {
    throw new Error('unregistered human approval was dismissed protectively');
  }

  const initialPr = {
    number: 99,
    head: {sha: 'new-head'},
    base: {ref: 'main', sha: 'base-head'},
    user: {login: 'nathanjohnpayne'},
    body: 'Authoring-Agent: cursor',
    labels: [],
  };
  const editedPr = {
    ...initialPr,
    user: {login: 'renamed-author'},
    body: 'Authoring-Agent: codex',
  };
  const policySnapshot = pr => JSON.stringify({
    head: pr.head.sha,
    baseRef: pr.base.ref,
    baseSha: pr.base.sha,
  });
  const enforcementSnapshot = pr =>
    approvalEnforcementSnapshot(pr, policySnapshot);
  let listCalls = 0;
  let readCalls = 0;
  let retryNotices = 0;
  const stable = await readStableReviewSnapshot({
    pr: initialPr,
    triageSnapshot: policySnapshot(initialPr),
    policySnapshot,
    enforcementSnapshot,
    listReviews: async () => {
      listCalls += 1;
      return [];
    },
    readPr: async () => {
      readCalls += 1;
      return editedPr;
    },
    notice: () => { retryNotices += 1; },
  });
  const prepared = prepareDirectApproval({
    liveReviews: stable.reviews,
    directReview,
    eventEnforcementCurrent: false,
    liveHeadSha: stable.pr.head.sha,
  });
  if (
    stable.pr !== editedPr ||
    stable.attempts !== 2 ||
    listCalls !== 2 ||
    readCalls !== 2 ||
    retryNotices !== 1 ||
    prepared.reviews.length !== 1 ||
    prepared.reviews[0] !== directReview ||
    prepared.directAttributionCurrent
  ) {
    throw new Error('mid-read mutation abandoned the empty-list durable fallback');
  }

  let headDriftRejected = false;
  try {
    await readStableReviewSnapshot({
      pr: initialPr,
      triageSnapshot: policySnapshot(initialPr),
      policySnapshot,
      enforcementSnapshot,
      listReviews: async () => [],
      readPr: async () => ({
        ...editedPr,
        head: {sha: 'later-head'},
      }),
      notice: () => {},
    });
  } catch (error) {
    headDriftRejected = /head\/base changed/.test(String(error));
  }
  if (!headDriftRejected) {
    throw new Error('head drift after triage did not fail closed');
  }

  const forceOnPr = {
    ...initialPr,
    labels: [{name: 'needs-external-review'}],
  };
  let forceOnReads = 0;
  const forceOnStable = await readStableReviewSnapshot({
    pr: initialPr,
    triageSnapshot: policySnapshot(initialPr),
    policySnapshot,
    enforcementSnapshot,
    listReviews: async () => [],
    readPr: async () => {
      forceOnReads += 1;
      return forceOnPr;
    },
    notice: () => {},
  });
  if (
    forceOnStable.attempts !== 2 ||
    forceOnReads !== 2 ||
    !phase4RequiredForApprovalGuard('false', forceOnStable.pr)
  ) {
    throw new Error('force-on label overlap was not retried and applied to live requiredness');
  }

  let removalReads = 0;
  const removalStable = await readStableReviewSnapshot({
    pr: forceOnPr,
    triageSnapshot: policySnapshot(forceOnPr),
    policySnapshot,
    enforcementSnapshot,
    listReviews: async () => [],
    readPr: async () => {
      removalReads += 1;
      return initialPr;
    },
    notice: () => {},
  });
  if (
    removalStable.attempts !== 2 ||
    removalReads !== 2 ||
    phase4RequiredForApprovalGuard('false', removalStable.pr)
  ) {
    throw new Error('force-on label removal was not retried and cleared from live requiredness');
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
NODE

# #1525: invoke the actual github-script guard with fake read/write APIs.
APPROVAL_ROOT="$ROOT" APPROVAL_WORKFLOW="$WORKFLOW" node <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = process.env.APPROVAL_ROOT;
const {retryGithubRead, selectApprovalTriage} = require(path.join(root, 'scripts/workflow/approval-triage.cjs'));
const source = fs.readFileSync(process.env.APPROVAL_WORKFLOW, 'utf8');
const step = source.slice(source.indexOf('      - name: Classify and dismiss ineligible approvals'));
const scriptLines = step.slice(step.indexOf('          script: |\n') + '          script: |\n'.length).split('\n');
const script = [];
for (const line of scriptLines) {
  if (line && !line.startsWith('            ')) break;
  script.push(line.replace(/^ {12}/, ''));
}
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const guard = new AsyncFunction('github', 'context', 'core', 'require', script.join('\n'));
const workflowRequire = name => require(name.startsWith('./') ? path.resolve(root, name) : name);
const head = 'a'.repeat(40);
const pr = {number: 99, head: {sha: head}, base: {ref: 'main', sha: 'b'.repeat(40)},
  user: {login: 'nathanjohnpayne'}, body: 'Authoring-Agent: codex', labels: [{name: 'priority:high'}]};
const clone = value => JSON.parse(JSON.stringify(value));
async function main() {
  for (const error of [Object.assign(new Error('write EPIPE'), {code:'EPIPE'}),
    Object.assign(new Error('reset'), {cause:{code:'ECONNRESET'}}), new Error('fetch failed'),
    Object.assign(new Error('server'), {status:503}), Object.assign(new Error('rate'), {status:429})]) {
    let calls = 0; const waits = [];
    assert.equal(await retryGithubRead(async () => { if (++calls < 3) throw error; return 'ok'; },
      async ms => waits.push(ms)), 'ok');
    assert.equal(calls, 3); assert.deepEqual(waits, [250,500]);
  }
  for (const status of [401,403,404,422]) {
    let calls = 0;
    await assert.rejects(retryGithubRead(async () => { calls++; throw Object.assign(new Error('fetch failed'), {status}); }, async () => {}));
    assert.equal(calls, 1);
  }
  let exhausted = 0;
  await assert.rejects(retryGithubRead(async () => { exhausted++; throw new Error('fetch failed'); }, async () => {}));
  assert.equal(exhausted, 3);
  process.env.GITHUB_WORKSPACE = root;
  process.env.TRIAGE_RESULT = 'failure';
  process.env.REVIEWERS_JSON = '["nathanpayne-claude"]';
  process.env.EVENT_REVIEWERS_JSON = '["nathanpayne-claude"]';
  assert.equal(selectApprovalTriage({modulePresent:false,trustedWorkflow:'old workflow',loadBootstrap:()=>'fallback'}), 'fallback');
  assert.throws(() => selectApprovalTriage({modulePresent:false,trustedWorkflow:source,loadBootstrap:()=>'fallback'}), /requires the missing/);
  assert.throws(() => selectApprovalTriage({modulePresent:true,trustedWorkflow:'old workflow',loadCanonical:()=>{throw new Error('broken canonical');},loadBootstrap:()=>'fallback'}), /broken canonical/);
  for (const mode of ['stable','null-body','first-rollout','EPIPE','head','base-ref','base-sha','body','labels','author','late-drift','old-approval','malformed','unreadable','missing-canonical','unregistered','not-approved','non-review']) {
    let reads = 0; let dismissed = 0; const outputs = {}; const failed = []; const notices = [];
    const eventPr = clone(pr);
    if (mode === 'null-body') eventPr.body = null;
    const review = {id:301,state:'approved',commit_id:head,user:{login:'nathanpayne-claude'}};
    if (mode === 'old-approval') review.commit_id = 'c'.repeat(40);
    if (mode === 'unregistered') review.user.login = 'human-reviewer';
    if (mode === 'not-approved') review.state = 'commented';
    const github = {rest:{pulls:{
      get: async () => {
        reads++;
        if (mode === 'EPIPE' && reads === 1) throw Object.assign(new Error('write EPIPE'), {code:'EPIPE'});
        if (mode === 'unreadable') throw Object.assign(new Error('not found'), {status:404});
        const live = clone(eventPr);
        if (mode === 'head' || (mode === 'late-drift' && reads === 2)) live.head.sha = 'd'.repeat(40);
        if (mode === 'base-ref') live.base.ref = 'other';
        if (mode === 'base-sha') live.base.sha = 'd'.repeat(40);
        if (mode === 'body') live.body += ' edited';
        if (mode === 'labels') live.labels.push({name:'human-hold'});
        if (mode === 'author') live.user.login = 'other-author';
        if (mode === 'malformed') live.labels = null;
        return {data:live};
      },
      dismissReview: async () => { dismissed++; },
    }}};
    await guard(github, {eventName:mode === 'non-review' ? 'pull_request' : 'pull_request_review',repo:{owner:'owner',repo:'repo'},
      payload:{pull_request:eventPr,review}}, {
      setOutput:(key,value) => { outputs[key]=value; }, setFailed:message => failed.push(message),
      notice:message => notices.push(message), info:() => {},
    }, ['first-rollout','missing-canonical'].includes(mode) ? name => {
      if (name === 'fs') return {...fs,
        existsSync:file => String(file).endsWith('approval-triage.cjs') ? false : fs.existsSync(file),
        readFileSync:(file,...args) => String(file).endsWith('agent-review.yml')
          ? (mode === 'first-rollout' ? source.replaceAll('const approvalTriage = selectApprovalTriage(', 'old-helper-rollout') : source)
          : fs.readFileSync(file,...args)};
      return workflowRequire(name);
    } : workflowRequire);
    const preserved = ['stable','null-body','first-rollout','EPIPE'].includes(mode);
    assert.equal(dismissed, preserved || ['unregistered','not-approved','non-review'].includes(mode) ? 0 : 1, mode);
    assert.deepEqual(outputs, {eligible_approval:'false',snapshot_current:'false'}, mode);
    assert.equal(failed.length, 1, mode);
    assert.equal(notices.some(message => message.includes('preserving the approval')), preserved, mode);
    if (mode === 'stable') assert.equal(reads, 2);
    if (mode === 'EPIPE') assert.equal(reads, 3);
  }
  console.log('Approval triage: 10 bounded-retry, 3 canonical-loader and 18 production-guard cases passed');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
NODE

# #2178: a blocking execFileSync before the label write froze the event loop,
# so undici reused a keep-alive socket the server had already closed and the
# POST failed with "other side closed". Triage helpers must run without
# blocking, and the one idempotent label write retries once.
printf "let childProcess = require('child_process');\n" >"$TRIAGE_IO_MODULE"
awk '
  /BEGIN TRIAGE EVENT-LOOP-SAFE IO/ { capture=1; next }
  /END TRIAGE EVENT-LOOP-SAFE IO/   { capture=0 }
  capture {
    sub(/^            /, "")
    print
  }
' "$WORKFLOW" >>"$TRIAGE_IO_MODULE"
if ! grep -qF 'function execFileAsync(' "$TRIAGE_IO_MODULE" ||
  ! grep -qF 'function retryIdempotentLabelWrite(' "$TRIAGE_IO_MODULE"; then
  echo "FAIL: could not extract the triage event-loop-safe IO helpers from $WORKFLOW" >&2
  exit 1
fi
printf '\nmodule.exports = { execFileAsync, retryIdempotentLabelWrite, useChildProcess: value => { childProcess = value; } };\n' >>"$TRIAGE_IO_MODULE"

TRIAGE_IO_PATH="$TRIAGE_IO_MODULE" TRIAGE_ROOT="$ROOT" TRIAGE_WORKFLOW="$WORKFLOW" \
TRIAGE_STEP_TMP="$TRIAGE_STEP_TMP" node <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {EventEmitter} = require('node:events');
const {execFileAsync, retryIdempotentLabelWrite, useChildProcess} = require(process.env.TRIAGE_IO_PATH);
const node = process.execPath;

async function quietStderr(run) {
  const chunks = [];
  const write = process.stderr.write;
  process.stderr.write = chunk => { chunks.push(String(chunk)); return true; };
  try { await run(); } finally { process.stderr.write = write; }
  return chunks.join('');
}

// Octokit wraps a fetch transport failure as status 500 whose cause chain
// ends in undici's SocketError, exactly as the #2178 runs logged it.
const socketClosed = () => Object.assign(new Error('other side closed'), {
  status: 500,
  cause: Object.assign(new TypeError('fetch failed'), {
    cause: Object.assign(new Error('other side closed'), {code: 'UND_ERR_SOCKET'}),
  }),
});
const httpError = status => Object.assign(new Error(`HTTP ${status}`), {status, response: {status}});

async function helperCases() {
  let ticks = 0;
  const ticker = setInterval(() => { ticks += 1; }, 10);
  const out = await execFileAsync(node, ['-e', 'setTimeout(() => process.stdout.write("done"), 300)'],
    {encoding: 'utf8'});
  clearInterval(ticker);
  assert.equal(out, 'done');
  assert.ok(ticks >= 5, `the event loop must keep running while a helper runs (ticked ${ticks})`);

  assert.equal(await execFileAsync(node, ['-e', 'process.stdin.pipe(process.stdout)'],
    {input: '{"number":2178}', encoding: 'utf8'}), '{"number":2178}');
  assert.equal(await execFileAsync(node, ['-e',
    'let n = 0; process.stdin.on("data", c => { n += c.length; }).on("end", () => process.stdout.write(String(n)))'],
    {encoding: 'utf8', timeout: 10000}), '0', 'a helper without input must see EOF, not hang');

  const forwarded = await quietStderr(() => assert.rejects(
    execFileAsync(node, ['-e', 'process.stderr.write("refused"); process.exit(3)'], {encoding: 'utf8'}),
    error => error.code === 3 && /refused/.test(error.message)));
  assert.match(forwarded, /refused/, 'helper stderr must still reach the job log');

  await assert.rejects(execFileAsync(node, ['-e', 'setTimeout(() => {}, 5000)'],
    {encoding: 'utf8', timeout: 200}), error => error.killed === true);
  await assert.rejects(execFileAsync(node, ['-e', 'process.exit(0)'],
    {input: 'x'.repeat(4 * 1024 * 1024), encoding: 'utf8'}), error => error.code === 'EPIPE',
    'an input the helper never read must reject, as execFileSync does');

  // Node calls back once stdout and stderr close; stdin is not awaited. Force
  // the late ordering: exit 0 first, then EPIPE on the unread input.
  useChildProcess({execFile(file, args, options, callback) {
    const stdin = Object.assign(new EventEmitter(), {closed: false, end() {}});
    setTimeout(() => callback(null, 'verified', ''), 1);
    setTimeout(() => {
      stdin.emit('error', Object.assign(new Error('write EPIPE'), {code: 'EPIPE'}));
      stdin.closed = true;
      stdin.emit('close');
    }, 20);
    return {stdin, stderr: new EventEmitter()};
  }});
  try {
    await assert.rejects(execFileAsync('bash', ['verify'], {input: '{}', encoding: 'utf8'}),
      error => error.code === 'EPIPE', 'an EPIPE after the exit callback must still reject');
  } finally {
    useChildProcess(require('node:child_process'));
  }
  return 7;
}

async function retryCases() {
  let cases = 0;
  for (const make of [socketClosed,
    () => Object.assign(new TypeError('fetch failed'), {cause: {code: 'UND_ERR_SOCKET', message: 'other side closed'}}),
    () => Object.assign(new Error('read ECONNRESET'), {code: 'ECONNRESET'}),
    () => httpError(502)]) {
    let calls = 0; const waits = []; const warnings = [];
    assert.deepEqual(await retryIdempotentLabelWrite(async () => {
      if (++calls === 1) throw make();
      return {data: [{name: 'needs-external-review'}]};
    }, {wait: async ms => waits.push(ms), warn: message => warnings.push(message)}),
    {data: [{name: 'needs-external-review'}]});
    assert.equal(calls, 2); assert.deepEqual(waits, [500]); assert.equal(warnings.length, 1);
    cases += 1;
  }
  for (const make of [() => httpError(401), () => httpError(403), () => httpError(404),
    () => httpError(422), () => new TypeError('github.rest.issues.addLabels is not a function')]) {
    let calls = 0;
    await assert.rejects(retryIdempotentLabelWrite(async () => { calls += 1; throw make(); },
      {wait: async () => {}, warn: () => {}}));
    assert.equal(calls, 1, 'a 4xx or a non-transport error must not be retried');
    cases += 1;
  }
  let calls = 0;
  await assert.rejects(retryIdempotentLabelWrite(async () => { calls += 1; throw socketClosed(); },
    {wait: async () => {}, warn: () => {}}), /other side closed/);
  assert.equal(calls, 2, 'exactly one retry, then fail closed');
  return cases + 1;
}

// Run the real triage step with fake GitHub APIs and a child_process whose
// execFileSync throws, so any blocking helper call left in the step either
// fails it or turns into a fail-closed result the assertions catch.
async function productionStepCases() {
  const root = process.env.TRIAGE_ROOT;
  const source = fs.readFileSync(process.env.TRIAGE_WORKFLOW, 'utf8');
  const step = source.slice(source.indexOf('      - name: Evaluate PR against review-policy.yml'));
  const scriptLines = step.slice(step.indexOf('          script: |\n') + '          script: |\n'.length).split('\n');
  const script = [];
  for (const line of scriptLines) {
    if (line && !line.startsWith('            ')) break;
    script.push(line.replace(/^ {12}/, ''));
  }
  const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
  const triage = new AsyncFunction('github', 'context', 'core', 'require', script.join('\n'));
  const head = 'a'.repeat(40);
  const base = 'b'.repeat(40);
  const pr = {number: 2178, head: {sha: head}, base: {ref: 'main', sha: base},
    user: {login: 'nathanjohnpayne'}, body: 'Authoring-Agent: claude', labels: []};
  const clone = value => JSON.parse(JSON.stringify(value));
  Object.assign(process.env, {GITHUB_WORKSPACE: root, TMPDIR: process.env.TRIAGE_STEP_TMP,
    THRESHOLD: '300', PROTECTED_PATHS: '[".github/**"]'});
  const allHelpers = ['git', 'resolve_base_policy.sh', 'load_review_config.sh',
    'external_review_fingerprint.sh', 'verify-live-propagation.sh', 'external_review_carryforward.sh'];
  // #2727 3d: the step runs the default branch's review-triage.cjs, and its
  // generated copy only where that module is absent. Two workspaces stand in
  // for such default branches: one whose workflow predates the selection (the
  // copy must run), and one whose workflow selects the module but lacks the
  // file (the step must fail closed, before any read).
  const workspace = name => {
    const dir = fs.mkdtempSync(path.join(process.env.TRIAGE_STEP_TMP, `${name}-`));
    fs.mkdirSync(path.join(dir, 'scripts/workflow'), {recursive: true});
    fs.mkdirSync(path.join(dir, '.github/workflows'), {recursive: true});
    fs.copyFileSync(path.join(root, 'scripts/workflow/approval-triage.cjs'),
      path.join(dir, 'scripts/workflow/approval-triage.cjs'));
    return dir;
  };
  const bootstrapWorkspace = workspace('bootstrap');
  fs.writeFileSync(path.join(bootstrapWorkspace, '.github/workflows/agent-review.yml'),
    source.replace(/const reviewTriagePath = path\.resolve\(/g, 'const legacyTriage = ('));
  const brokenWorkspace = workspace('broken');
  fs.copyFileSync(process.env.TRIAGE_WORKFLOW, path.join(brokenWorkspace, '.github/workflows/agent-review.yml'));
  // A default-branch module that differs from the workflow's copy: the step
  // must run it, with the step's require and mutate true.
  const moduleWorkspace = workspace('module');
  fs.copyFileSync(process.env.TRIAGE_WORKFLOW, path.join(moduleWorkspace, '.github/workflows/agent-review.yml'));
  fs.writeFileSync(path.join(moduleWorkspace, 'scripts/workflow/review-triage.cjs'),
    "module.exports = {evaluateReviewTriage: async ({core, require, mutate}) => " +
    "core.setOutput('ran', `default-branch module, mutate=${mutate}, require=${typeof require}`)};\n");
  const triageModule = require(path.join(root, 'scripts/workflow/review-triage.cjs'));
  const classifyOnly = (github, context, core, require) =>
    triageModule.evaluateReviewTriage({github, context, core, require, mutate: false});
  const scenarios = [
    {name: 'socket closed once', labelFailures: [socketClosed], resolves: true, labelCalls: 2, needsExternal: 'true',
      addsLabel: 'true'},
    {name: 'approved review, socket closed once', event: 'pull_request_review', labelFailures: [socketClosed],
      resolves: true, labelCalls: 2, needsExternal: 'true', addsLabel: 'true'},
    {name: 'socket closed twice', labelFailures: [socketClosed, socketClosed], resolves: false, labelCalls: 2},
    {name: 'forbidden', labelFailures: [() => httpError(403)], resolves: false, labelCalls: 1},
    {name: 'carried forward', carried: true, labelFailures: [], resolves: true, labelCalls: 0, needsExternal: 'false',
      addsLabel: 'false'},
    {name: 'generated copy where the module is not on the default branch', workspace: bootstrapWorkspace,
      labelFailures: [], resolves: true, labelCalls: 1, needsExternal: 'true', addsLabel: 'true'},
    {name: 'classify only (mutate false) decides the label without writing it', run: classifyOnly,
      labelFailures: [], resolves: true, labelCalls: 0, needsExternal: 'true', addsLabel: 'true'},
    {name: 'the default branch module runs instead of the copy', workspace: moduleWorkspace, labelFailures: [],
      resolves: true, labelCalls: 0, ran: 'default-branch module, mutate=true, require=function'},
    {name: 'module missing where the default branch selects it', workspace: brokenWorkspace,
      labelFailures: [], resolves: false, labelCalls: 0, rejects: /requires the missing scripts\/workflow\/review-triage\.cjs/},
  ];
  for (const scenario of scenarios) {
    process.env.GITHUB_WORKSPACE = scenario.workspace || root;
    const record = {sync: 0, helpers: [], verifierInput: null, labelCalls: 0};
    const outputs = {}; const warnings = [];
    const childProcess = {
      execFileSync() {
        record.sync += 1;
        throw new Error('execFileSync blocks the event loop before the label write (#2178)');
      },
      execFile(file, args, options, callback) {
        const helper = file === 'git' ? 'git' : path.basename(args[0]);
        record.helpers.push(helper);
        const stdin = {closed: false, on() { return this; }, once() { return this; },
          end(data) { if (helper === 'verify-live-propagation.sh') record.verifierInput = data; this.closed = true; }};
        let error = null; let stdout = '';
        if (helper === 'git') stdout = `${base}\n`;
        if (helper === 'resolve_base_policy.sh') stdout = '.github/review-policy.yml\n';
        if (helper === 'load_review_config.sh') {
          fs.writeFileSync(args[args.indexOf('--output') + 1],
            'reviewers=["nathanpayne-claude","nathanpayne-codex"]\nauthor_identity=nathanjohnpayne\n');
        }
        if (helper === 'external_review_fingerprint.sh') stdout = JSON.stringify({requires_review: true, fingerprint: 'fp-2178'});
        if (helper === 'verify-live-propagation.sh') {
          error = Object.assign(new Error('Command failed: bash scripts/workflow/verify-live-propagation.sh'), {code: 1});
        }
        if (helper === 'external_review_carryforward.sh') {
          stdout = JSON.stringify(scenario.carried
            ? {carried: true, source_commit: 'c'.repeat(40), source_time: '2026-10-14T00:00:00Z'}
            : {carried: false});
        }
        setTimeout(() => callback(error, stdout, ''), 5);
        return {stdin, stderr: {on() { return this; }}};
      },
    };
    const failures = [...scenario.labelFailures];
    const github = {
      paginate: async () => [{filename: '.github/workflows/agent-review.yml', additions: 10, deletions: 2}],
      rest: {
        pulls: {get: async () => ({data: clone(pr)}), listFiles() {}},
        issues: {addLabels: async params => {
          record.labelCalls += 1;
          assert.deepEqual(params.labels, ['needs-external-review']);
          const failure = failures.shift();
          if (failure) throw failure();
          return {data: [{name: 'needs-external-review'}]};
        }},
      },
    };
    const eventName = scenario.event || 'pull_request';
    const context = {eventName, repo: {owner: 'o', repo: 'r'}, payload: {
      action: eventName === 'pull_request' ? 'synchronize' : 'submitted',
      pull_request: clone(pr), repository: {default_branch: 'main'},
      review: eventName === 'pull_request' ? undefined : {id: 1, state: 'approved', commit_id: head}}};
    const core = {setOutput: (key, value) => { outputs[key] = value; }, warning: message => warnings.push(message),
      notice: () => {}, info: () => {}, setFailed: () => {}};
    const fakeRequire = name => name === 'child_process' ? childProcess : require(name);
    const log = console.log;
    console.log = () => {};
    let rejection = null;
    try {
      await (scenario.run || triage)(github, context, core, fakeRequire);
    } catch (error) {
      rejection = error;
    } finally {
      console.log = log;
    }
    assert.equal(rejection === null, scenario.resolves, `${scenario.name}: ${rejection && rejection.message}`);
    if (scenario.ran) {
      assert.deepEqual(outputs, {ran: scenario.ran}, scenario.name);
      assert.deepEqual(record.helpers, [], `${scenario.name}: the copy ran`);
      continue;
    }
    if (scenario.rejects) {
      assert.match(rejection.message, scenario.rejects, scenario.name);
      assert.deepEqual(record.helpers, [], `${scenario.name}: no helper may run before the refusal`);
      assert.equal(record.labelCalls, 0, scenario.name);
      assert.deepEqual(outputs, {}, `${scenario.name}: a refusal must not export a result`);
      continue;
    }
    assert.equal(record.sync, 0, `${scenario.name}: triage called execFileSync`);
    assert.deepEqual(record.helpers, allHelpers, `${scenario.name}: every helper must run through execFile`);
    assert.equal(JSON.parse(record.verifierInput).number, 2178, `${scenario.name}: verifier input`);
    assert.equal(record.labelCalls, scenario.labelCalls, scenario.name);
    assert.ok(!warnings.some(message => /fingerprint|carry-forward|governing/i.test(message)),
      `${scenario.name}: a helper fell back fail-closed: ${warnings.join(' | ')}`);
    if (scenario.resolves) {
      assert.equal(outputs.needs_external, scenario.needsExternal, scenario.name);
      assert.equal(outputs.phase_4_intrinsic_required, 'true', scenario.name);
      assert.equal(outputs.reviewers, '["nathanpayne-claude","nathanpayne-codex"]', scenario.name);
      assert.equal(outputs.adds_external_label, scenario.addsLabel, scenario.name);
    } else {
      assert.equal(outputs.needs_external, undefined, `${scenario.name}: a failed label write must not export a result`);
    }
  }
  return scenarios.length;
}

async function main() {
  const helpers = await helperCases();
  const retries = await retryCases();
  const steps = await productionStepCases();
  console.log(`Triage IO: ${helpers} non-blocking helper, ${retries} label-retry and ${steps} production-step cases passed`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
NODE

echo "test_self_approval_detector: PASS"
