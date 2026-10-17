#!/usr/bin/env node
'use strict';

// Deterministic escalation only. A clear result is not a hostile-diff safety proof.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const SENSITIVE_PATHS = [
  /^(?:.*\/)?AGENTS\.md$/,
  /^REVIEW_POLICY\.md$/,
  /^\.codex\/hooks\.json$/,
  /^\.claude\/settings\.json$/,
  /^\.github\/review-policy\.yml$/,
  /^\.mergepath-sync\.yml$/,
  /^scripts\/sync-to-downstream\.sh$/,
  /^scripts\/coderabbit-wait\.sh$/,
  /^scripts\/coderabbit-automerge-rate-limit-gate\.sh$/,
  /^scripts\/gate-api-lineage-blocking\.sh$/,
  /^scripts\/review-feedback-surface-fingerprint\.sh$/,
  /^scripts\/(?:codex|coderabbit)-record-feedback\.sh$/,
  /^scripts\/post-phase-4b-handoff\.sh$/,
  /^scripts\/wave-audit\.sh$/,
  /^\.github\/(?:workflows|actions)\//,
  /^scripts\/(?:phase-4b(?:\/|-)|gh-as-|identity-check\.sh$|op-preflight\.sh$)/,
  /^scripts\/(?:codex-review-|codex-p1-gate|coderabbit-severity-gate|merge-clearance-gate|required-head-checks|admin-merge|resolve-pr-threads|request-label-removal|render-feedback-archive|dispatch-thread-resolution)/,
  /^scripts\/(?:lib|workflow|hooks)\//,
  /^scripts\/(?:self-approval-detector|disagreement-detector)\.cjs$/,
  /^scripts\/(?:review-feedback-accounting\.sh$|firebase\/|gcloud\/|deploy)/,
];

// Deliberately finite literal alarms, including inert examples and removed text.
// Ordinary mentions of review results do not by themselves address the reviewer.
const ADDRESSEE = /\b(?:dear\s+reviewer|you\s+are\s+(?:the\s+)?(?:reviewer|review agent)|as\s+(?:the\s+)?reviewer)\b|\b(?:reviewer|review agent|codex|claude|assistant)\s*:/i;
const VERDICT_REQUEST = /\b(?:ignore|disregard|override|bypass|skip|approve|reject|output|emit|return|set|write|report|change)\b[^\r\n]{0,160}\b(?:reviewer|review instructions|verdict|APPROVED|CHANGES_REQUESTED)\b/i;

function classify(diff, files) {
  const tripwires = [];
  if (ADDRESSEE.test(diff)) tripwires.push('reviewer-address');
  if (VERDICT_REQUEST.test(diff)) tripwires.push('verdict-instruction');
  if (files.some(file => SENSITIVE_PATHS.some(pattern => pattern.test(file)))) {
    tripwires.push('authorization-policy-publisher-or-credentials');
  }
  return { decision: tripwires.length ? 'human-review' : 'model-review', tripwires };
}

function capturedInput(directory) {
  const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'input.json'), 'utf8'));
  for (const key of ['merge_base_sha', 'head_sha']) {
    if (!/^[0-9a-f]{40}$/.test(metadata[key])) throw new Error('invalid capture');
  }
  // Curated wave input must not hide the complete consumer PR's sensitive changes.
  const wave = Object.hasOwn(metadata, 'pr_diff_sha256');
  const diff = fs.readFileSync(path.join(directory, wave ? 'pr.diff' : 'review.diff'));
  const expected = wave ? metadata.pr_diff_sha256 : metadata.diff_sha256;
  if (!/^[0-9a-f]{64}$/.test(expected) || crypto.createHash('sha256').update(diff).digest('hex') !== expected) {
    throw new Error('changed capture');
  }
  const env = { PATH: process.env.PATH, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_COUNT: '0' };
  const files = execFileSync('git', [
    '--git-dir', path.join(directory, 'objects.git'), 'diff', '--no-ext-diff', '--no-textconv',
    '--no-renames', '--name-only', '-z', metadata.merge_base_sha, metadata.head_sha, '--',
  ], { env, timeout: 30000, maxBuffer: 16 * 1024 * 1024 }).toString('utf8').split('\0').filter(Boolean);
  return classify(diff.toString('utf8'), files);
}

if (require.main === module) {
  try {
    if (process.argv.length !== 3) throw new Error('capture directory required');
    process.stdout.write(JSON.stringify(capturedInput(process.argv[2])) + '\n');
  } catch {
    // Do not echo candidate text or subprocess output into credentialed logs.
    process.stderr.write('Phase 4b escalation input could not be verified.\n');
    process.exitCode = 2;
  }
}

module.exports = { classify, capturedInput };
