#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/self-approval-detector.cjs"
WORKFLOW="$ROOT/.github/workflows/agent-review.yml"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available" >&2
  exit 0
fi

BOOTSTRAP_MODULE="$(mktemp "${TMPDIR:-/tmp}/self-approval-bootstrap.XXXXXX.cjs")"
trap 'rm -f "$BOOTSTRAP_MODULE"' EXIT
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
printf '\nmodule.exports = { bootstrapDetector, selectDetector };\n' >> "$BOOTSTRAP_MODULE"

DETECTOR_PATH="$DETECTOR" BOOTSTRAP_PATH="$BOOTSTRAP_MODULE" node <<'NODE'
const canonical = require(process.env.DETECTOR_PATH);
const { bootstrapDetector, selectDetector } = require(process.env.BOOTSTRAP_PATH);
const implementations = [
  ['canonical', canonical],
  ['bootstrap', bootstrapDetector()],
];

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
    const expectedPersistentViolation = [
      'same-native-account-approval',
      'same-agent-phase-4-approval',
    ].includes(expectedReason);
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

const canonicalSentinel = {name: 'canonical'};
const bootstrapSentinel = {name: 'bootstrap'};
let canonicalLoads = 0;
let bootstrapLoads = 0;
const modulePresent = selectDetector({
  modulePresent: true,
  trustedWorkflow: 'SELF_APPROVAL_DETECTOR_REQUIRED_V1',
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

const legacyTrustedWorkflow = selectDetector({
  modulePresent: false,
  trustedWorkflow: 'name: Agent Review Pipeline\n# legacy workflow',
  loadCanonical: () => canonicalSentinel,
  loadBootstrap: () => {
    bootstrapLoads += 1;
    return bootstrapSentinel;
  },
});
if (legacyTrustedWorkflow !== bootstrapSentinel || bootstrapLoads !== 1) {
  throw new Error('legacy trusted workflow did not select the bounded bootstrap');
}

let markerMissingModuleFailed = false;
try {
  selectDetector({
    modulePresent: false,
    trustedWorkflow: 'SELF_APPROVAL_DETECTOR_REQUIRED_V1',
    loadCanonical: () => canonicalSentinel,
    loadBootstrap: () => bootstrapSentinel,
  });
} catch (error) {
  markerMissingModuleFailed = /already requires the detector/.test(String(error));
}
if (!markerMissingModuleFailed) {
  throw new Error('marker-bearing trusted workflow with a missing module did not fail closed');
}
NODE

echo "test_self_approval_detector: PASS"
