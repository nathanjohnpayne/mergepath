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
RENDER_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/self-approval-renderer.XXXXXX")"
trap 'rm -f "$BOOTSTRAP_MODULE" "$DISMISS_MODULE" "$PROTECTION_MODULE" "$SNAPSHOT_MODULE" "$TRIAGE_POLICY_MODULE" "$APPROVAL_PHASE4_MODULE"; rm -rf "$RENDER_FIXTURE"' EXIT

# JavaScript replacement strings interpret $&, $`, $', $1, $<name>, and $$.
# Canonical detector source is arbitrary text, so the renderer must preserve
# every such sequence byte-for-byte in both generated workflow mirrors.
mkdir -p "$RENDER_FIXTURE/scripts" "$RENDER_FIXTURE/.github/workflows"
cp "$DETECTOR" "$RENDER_FIXTURE/scripts/self-approval-detector.cjs"
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

echo "test_self_approval_detector: PASS"
