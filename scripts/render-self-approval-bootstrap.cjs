#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const detectorPath = path.join(root, 'scripts/self-approval-detector.cjs');
const workflowPath = path.join(root, '.github/workflows/agent-review.yml');
const sourceBegin = '// BEGIN SELF-APPROVAL DETECTOR IMPLEMENTATION';
const sourceEnd = '// END SELF-APPROVAL DETECTOR IMPLEMENTATION';
const labelSourceBegin = '// BEGIN STABLE PR LABEL NAMES';
const labelSourceEnd = '// END STABLE PR LABEL NAMES';
const targetBegin = '            // BEGIN SELF-APPROVAL BOOTSTRAP';
const targetEnd = '            // END SELF-APPROVAL BOOTSTRAP';
const labelTargetBegin =
  '            // BEGIN STABLE PR LABEL NAMES BOOTSTRAP';
const labelTargetEnd =
  '            // END STABLE PR LABEL NAMES BOOTSTRAP';

function fail(message) {
  process.stderr.write(`render-self-approval-bootstrap: ${message}\n`);
  process.exit(1);
}

function between(text, begin, end, label) {
  const beginAt = text.indexOf(begin);
  const secondBegin = text.indexOf(begin, beginAt + begin.length);
  const endAt = text.indexOf(end, beginAt + begin.length);
  const secondEnd = text.indexOf(end, endAt + end.length);
  if (
    beginAt < 0 ||
    endAt < 0 ||
    secondBegin >= 0 ||
    secondEnd >= 0 ||
    beginAt >= endAt
  ) {
    fail(`${label} must contain exactly one ordered marker pair`);
  }
  return text.slice(beginAt + begin.length, endAt).replace(/^\r?\n/, '').replace(/\r?\n$/, '');
}

const mode = process.argv[2] || '--check';
if (!['--check', '--write'].includes(mode) || process.argv.length > 3) {
  fail('usage: scripts/render-self-approval-bootstrap.cjs [--check|--write]');
}

const detector = fs.readFileSync(detectorPath, 'utf8');
const workflow = fs.readFileSync(workflowPath, 'utf8');
const implementation = between(detector, sourceBegin, sourceEnd, detectorPath);
const labelImplementation = between(
  detector,
  labelSourceBegin,
  labelSourceEnd,
  detectorPath,
);
const factory = [
  'function bootstrapDetector() {',
  ...implementation.split(/\r?\n/).map(line => (line ? `  ${line}` : '')),
  '  return {stablePrLabelNames, decide, latestApprovedReviews, reviewsWithDirectFallback, prepareDirectApproval, planApprovalEnforcement};',
  '}',
].join('\n');
const generated = [
  targetBegin,
  '            // Generated from scripts/self-approval-detector.cjs. Do not edit.',
  ...factory.split('\n').map(line => (line ? `            ${line}` : '')),
  targetEnd,
].join('\n');
const labelGenerated = [
  labelTargetBegin,
  '            // Generated from scripts/self-approval-detector.cjs. Do not edit.',
  ...labelImplementation.split(/\r?\n/).map(
    line => (line ? `            ${line}` : ''),
  ),
  labelTargetEnd,
].join('\n');
const currentBody = between(workflow, targetBegin, targetEnd, workflowPath);
const current = `${targetBegin}\n${currentBody}\n${targetEnd}`;
const labelCurrentBody = between(
  workflow,
  labelTargetBegin,
  labelTargetEnd,
  workflowPath,
);
const labelCurrent =
  `${labelTargetBegin}\n${labelCurrentBody}\n${labelTargetEnd}`;

if (current === generated && labelCurrent === labelGenerated) {
  process.stdout.write(
    'render-self-approval-bootstrap: PASS (generated mirrors are current)\n',
  );
  process.exit(0);
}

if (mode === '--check') {
  fail('generated workflow bootstrap is stale; run scripts/render-self-approval-bootstrap.cjs --write');
}

const updated = workflow
  .replace(current, () => generated)
  .replace(labelCurrent, () => labelGenerated);
if (updated === workflow) {
  fail('could not replace the workflow bootstrap blocks');
}
fs.writeFileSync(workflowPath, updated);
process.stdout.write('render-self-approval-bootstrap: updated .github/workflows/agent-review.yml\n');
