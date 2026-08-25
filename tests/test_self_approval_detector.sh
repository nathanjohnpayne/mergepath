#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/self-approval-detector.cjs"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available" >&2
  exit 0
fi

DETECTOR_PATH="$DETECTOR" node <<'NODE'
const { decide } = require(process.env.DETECTOR_PATH);

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

for (const [name, input, expectedAction, expectedReason, expectedDetail] of cases) {
  const actual = decide(input);
  if (
    actual.action !== expectedAction ||
    actual.reason !== expectedReason ||
    actual.detail !== expectedDetail
  ) {
    throw new Error(
      `${name}: expected ${expectedAction}/${expectedReason}/${expectedDetail}, got ${JSON.stringify(actual)}`,
    );
  }
}
NODE

echo "test_self_approval_detector: PASS"
