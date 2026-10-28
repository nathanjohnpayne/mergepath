'use strict';

// scripts/workflow/review-triage.cjs: the triage decision of agent-review.yml
// (caller C2 of ADR 0004; #2727 slice 3d). It classifies a PR against the
// governing review policy (threshold, protected paths, fingerprint
// carry-forward, propagation lane) and decides whether needs-external-review
// is added.
//
// The `triage` job runs this module from its default-branch checkout, so a
// PR's edits to the workflow's copy do not change its own classification. The
// workflow carries a generated copy (REVIEW TRIAGE BOOTSTRAP) that runs only
// where the module is not yet on the default branch: the PR that adds it and
// each consumer's first sync. scripts/render-self-approval-bootstrap.cjs keeps
// that copy, and the two blocks nested in this module, current.
//
// Inputs:
//   github   Octokit: reads, and the one label write when mutate is true
//   context  only eventName, payload.action, payload.label.name,
//            payload.pull_request, payload.repository.default_branch and
//            repo.{owner,repo}, so a workflow_run consumer can pass its own
//   core     setOutput, warning, notice
//   require  the caller's require; tests inject child_process through it
//   mutate   false decides without writing (the consumer's classify job)
//   env      THRESHOLD, PROTECTED_PATHS, GITHUB_WORKSPACE; the cwd is the
//            trusted checkout, whose scripts/workflow helpers it runs
// Outputs (core.setOutput): needs_external, phase_4_required,
//   phase_4_intrinsic_required, classified_head, classified_base_ref,
//   classified_base_sha, reviewers, author_identity, adds_external_label.

// BEGIN REVIEW TRIAGE IMPLEMENTATION
async function evaluateReviewTriage({github, context, core, require, mutate = true}) {
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
// BEGIN TRIAGE READ BOOTSTRAP
// Generated from scripts/workflow/approval-triage.cjs. Do not edit.
function bootstrapApprovalTriage() {
  // Read-only GitHub operations: retry transport failures, never policy drift or
  // a permanent authorization/not-found response. Three attempts, 250ms then 500ms backoff (750ms total).
  async function retryGithubRead(read, wait = ms => new Promise(resolve => setTimeout(resolve, ms))) {
    for (let attempt = 0; ; attempt += 1) {
      try {
        return await read();
      } catch (error) {
        const status = Number(error && error.status || 0);
        const detail = [error && error.code, error && error.message,
          error && error.cause && error.cause.code,
          error && error.cause && error.cause.message].join(' ');
        const permanent = status >= 400 && status < 500 && status !== 429;
        const transient = status === 429 || (status >= 500 && status <= 599) ||
          /EPIPE|ECONNRESET|ETIMEDOUT|fetch failed/i.test(detail);
        if (attempt >= 2 || permanent || !transient) throw error;
        await wait(250 * (attempt + 1));
      }
    }
  }

  // This only preserves an existing exact-event approval; it never classifies,
  // grants eligibility or permits merge while triage remains unsuccessful.
  async function preserveApprovalAfterTriageFailure(input) {
    const {review, registered, eventPr, readPr, snapshot} = input;
    if (registered !== true || !review || !Number.isInteger(review.id) || review.id <= 0 ||
        String(review.state).toUpperCase() !== 'APPROVED' ||
        !eventPr || !eventPr.head || !eventPr.head.sha ||
        !eventPr.base || !eventPr.base.ref || !eventPr.base.sha ||
        !eventPr.user || typeof eventPr.user.login !== 'string' || !eventPr.user.login ||
        (eventPr.body !== null && typeof eventPr.body !== 'string') || review.commit_id !== eventPr.head.sha) return false;
    try {
      const expected = snapshot(eventPr);
      const before = await retryGithubRead(readPr);
      if (snapshot(before) !== expected) return false;
      const after = await retryGithubRead(readPr);
      return snapshot(after) === expected;
    } catch {
      return false;
    }
  }

  function selectApprovalTriage(input) {
    if (input.modulePresent) return input.loadCanonical();
    if (input.trustedWorkflow.includes('const approvalTriage = selectApprovalTriage(')) {
      throw new Error('trusted workflow requires the missing approval-triage canonical helper');
    }
    return input.loadBootstrap();
  }
  return {retryGithubRead, preserveApprovalAfterTriageFailure, selectApprovalTriage};
}
// END TRIAGE READ BOOTSTRAP
const {selectApprovalTriage} = bootstrapApprovalTriage();
const approvalTriagePath = path.resolve(process.env.GITHUB_WORKSPACE,
  'scripts/workflow/approval-triage.cjs');
const approvalTriage = selectApprovalTriage({
  modulePresent: fs.existsSync(approvalTriagePath),
  trustedWorkflow: fs.readFileSync(path.resolve(process.env.GITHUB_WORKSPACE,
    '.github/workflows/agent-review.yml'), 'utf8'),
  loadCanonical: () => require(approvalTriagePath),
  loadBootstrap: bootstrapApprovalTriage,
});
const {retryGithubRead} = approvalTriage;

// BEGIN TRIAGE EVENT-LOOP-SAFE IO
// Trusted helpers run without blocking the event loop (#2178). A
// blocking execFileSync froze it for the whole helper run, about
// 30s for the carry-forward on a large PR. The server closed the
// idle keep-alive socket in that window, undici never saw the
// close, and the next label POST went out on the dead socket
// ("other side closed"). Same contract as execFileSync: resolves
// stdout, takes `input`, echoes stderr to the log, and rejects on
// a non-zero exit, a timeout, or an `input` the helper never read.
function execFileAsync(file, args, options = {}) {
  const {input, ...execOptions} = options;
  return new Promise((resolve, reject) => {
    let inputError = null;
    const child = childProcess.execFile(file, args, execOptions,
      (error, stdout) => {
        // Settle once stdin has closed, so an EPIPE on `input`
        // that lands after the exit still rejects.
        const settle = () => {
          if (error || inputError) reject(error || inputError);
          else resolve(stdout);
        };
        if (child.stdin.closed) settle();
        else child.stdin.once('close', settle);
      });
    child.stderr.on('data', chunk => process.stderr.write(chunk));
    child.stdin.on('error', error => {
      if (input !== undefined) inputError = error;
    });
    child.stdin.end(input);
  });
}

// Adding a label that is already present changes nothing, so a
// label add lost in transport or answered with a 5xx is safe to
// send again. One retry only: a 4xx or a second failure still
// throws, and the step fails closed as before.
async function retryIdempotentLabelWrite(write, {
  wait = ms => new Promise(resolve => setTimeout(resolve, ms)),
  warn = message => console.log(message),
} = {}) {
  try {
    return await write();
  } catch (error) {
    if (!labelWriteMayRetry(error)) throw error;
    warn(`Label write failed (${error.message}); retrying once.`);
    await wait(500);
    return await write();
  }
}

function labelWriteMayRetry(error) {
  const status = Number(error && error.status || 0);
  if (status >= 400 && status < 500) return false;
  if (status >= 500 && status <= 599) return true;
  const detail = [];
  for (let cause = error, depth = 0; cause && depth < 4;
    cause = cause.cause, depth += 1) {
    detail.push(cause.code, cause.message);
  }
  return /UND_ERR_SOCKET|other side closed|ECONNRESET|EPIPE|ETIMEDOUT|fetch failed/i
    .test(detail.join(' '));
}
// END TRIAGE EVENT-LOOP-SAFE IO

function parseReviewerList(raw, label) {
  let reviewers;
  try {
    reviewers = JSON.parse(raw || '[]');
  } catch (error) {
    throw new Error(`${label} reviewer allow-list is malformed`);
  }
  if (
    !Array.isArray(reviewers) ||
    reviewers.some(reviewer =>
      typeof reviewer !== 'string' || reviewer.trim().length === 0
    )
  ) {
    throw new Error(`${label} reviewer allow-list is malformed`);
  }
  return reviewers;
}

// BEGIN TRIAGE POLICY MATERIALIZATION DECISION
function shouldMaterializeDefaultPolicy({
  baseRef,
  baseSha,
  defaultBranch,
  checkoutSha,
}) {
  return baseRef === defaultBranch &&
    (!checkoutSha || checkoutSha !== baseSha);
}
// END TRIAGE POLICY MATERIALIZATION DECISION

// BEGIN TRIAGE PHASE 4 DECISION
// BEGIN STABLE PR LABEL NAMES BOOTSTRAP
// Generated from scripts/self-approval-detector.cjs. Do not edit.
function stablePrLabelNames(candidate) {
  const labels = candidate && candidate.labels;
  if (
    !Array.isArray(labels) ||
    labels.some(label =>
      !label || typeof label.name !== 'string' || !label.name.trim()
    )
  ) {
    throw new Error('live PR labels are unavailable or malformed');
  }
  return labels.map(label => label.name).sort();
}
// END STABLE PR LABEL NAMES BOOTSTRAP

function phase4RequiredForTriage({
  requiresReview,
  laneVerifiedHead,
  pr,
}) {
  const forceOn = stablePrLabelNames(pr)
    .includes('needs-external-review');
  return forceOn || phase4IntrinsicRequiredForTriage({
    requiresReview,
    laneVerifiedHead,
  });
}

function phase4IntrinsicRequiredForTriage({
  requiresReview,
  laneVerifiedHead,
}) {
  return Boolean(requiresReview) && !laneVerifiedHead;
}

function triageMayMutateLabels({eventName, action, labelName}) {
  if (eventName !== 'pull_request') return true;
  return action !== 'unlabeled' && !(
    action === 'labeled' &&
    labelName === 'needs-external-review'
  );
}
// END TRIAGE PHASE 4 DECISION

async function loadGoverningIdentities(pr, policyConfigPath) {
  const outputPath = path.join(
    os.tmpdir(),
    `mergepath-live-policy-${process.pid}-${Date.now()}.out`,
  );
  try {
    fs.writeFileSync(outputPath, '');
    await execFileAsync(
      'bash',
      [
        'scripts/workflow/load_review_config.sh',
        '--repo', `${context.repo.owner}/${context.repo.repo}`,
        '--base-ref', pr.base.ref,
        '--base-sha', pr.base.sha,
        '--default-branch', context.payload.repository.default_branch,
        '--default-config', policyConfigPath,
        '--output', outputPath,
      ],
      {encoding: 'utf8', env: process.env},
    );
    const outputs = new Map();
    for (const line of fs.readFileSync(outputPath, 'utf8').split(/\r?\n/)) {
      if (!line) continue;
      const separator = line.indexOf('=');
      if (separator <= 0) {
        throw new Error('governing policy output is malformed');
      }
      const key = line.slice(0, separator);
      if (outputs.has(key)) {
        throw new Error(`governing policy output repeats ${key}`);
      }
      outputs.set(key, line.slice(separator + 1));
    }
    const reviewers = parseReviewerList(
      outputs.get('reviewers'),
      'governing policy',
    );
    const authorIdentity = outputs.get('author_identity') || '';
    if (reviewers.length === 0 || !authorIdentity.trim()) {
      throw new Error(
        'governing policy identities are unavailable; refusing to classify approval',
      );
    }
    return {reviewers, authorIdentity};
  } finally {
    try {
      fs.unlinkSync(outputPath);
    } catch (error) {
      if (error && error.code !== 'ENOENT') throw error;
    }
  }
}
const eventPr = context.payload.pull_request;
const snapshotKey = candidate => JSON.stringify({
  head: candidate && candidate.head && candidate.head.sha,
  baseRef: candidate && candidate.base && candidate.base.ref,
  baseSha: candidate && candidate.base && candidate.base.sha,
  labels: stablePrLabelNames(candidate),
});
const {data: pr} = await retryGithubRead(() => github.rest.pulls.get({
  owner: context.repo.owner,
  repo: context.repo.repo,
  pull_number: eventPr.number,
}));
const triageSnapshot = snapshotKey(pr);
if (snapshotKey(eventPr) !== triageSnapshot) {
  core.notice(
    'The event PR snapshot is stale; triage is evaluating the ' +
    'current live head/base and the approval guard will suppress ' +
    'direct-event violation attribution for the stale webhook.',
  );
}
const eventLabelName = context.payload.label &&
  context.payload.label.name;
const isForceOnLabelEvent =
  context.eventName === 'pull_request' &&
  context.payload.action === 'labeled' &&
  eventLabelName === 'needs-external-review';
const isUnlabeledSettleEvent =
  context.eventName === 'pull_request' &&
  context.payload.action === 'unlabeled';
const mayMutateLabels = triageMayMutateLabels({
  eventName: context.eventName,
  action: context.payload.action,
  labelName: eventLabelName,
});
const threshold = parseInt(process.env.THRESHOLD, 10);
const protectedPaths = JSON.parse(process.env.PROTECTED_PATHS);

const files = await retryGithubRead(() => github.paginate(
  github.rest.pulls.listFiles,
  {
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: pr.number,
  }
));
const {data: prAfterFiles} = await retryGithubRead(() => github.rest.pulls.get({
  owner: context.repo.owner,
  repo: context.repo.repo,
  pull_number: eventPr.number,
}));
if (snapshotKey(prAfterFiles) !== triageSnapshot) {
  throw new Error(
    'PR head/base changed while triage read the live file list; ' +
    'refusing to classify a mixed snapshot. A newer event will retry.',
  );
}

// Config must come from the PR BASE, not this default-branch
// checkout (#763/#769). This job checks out the default branch so
// the HELPER code is trusted — correct, and unchanged — but the
// helper was then handed the default branch's review-policy.yml. A
// PR targeting a stricter non-default base was therefore judged by
// the LOOSER policy, and since `needsExternal` is overwritten by
// the helper result below, that could flip it to false and skip the
// external-review label entirely.
//
// Resolution goes through the SHARED helper that
// merge-clearance-gate.sh and codex-review-check.sh also use, so
// every policy decision in the fleet reads one implementation
// rather than four near-copies. For a default-base PR it returns
// the checked-out path and makes no API call; it fails (exit 2)
// only for a positively-identified non-default base whose policy
// cannot be read, which is the one case where silently using the
// default-branch copy would be the bypass.
let policyConfigPath = '.github/review-policy.yml';
let policyReadFailed = false;
try {
  let checkoutSha = '';
  try {
    checkoutSha = (await execFileAsync(
      'git',
      ['rev-parse', 'HEAD'],
      {encoding: 'utf8'},
    )).trim();
  } catch (error) {
    core.warning(
      `Could not prove the trusted checkout SHA (${error.message}); ` +
      `materializing the exact live default-base policy instead.`,
    );
  }
  const policyResolverArgs = [
    'scripts/workflow/resolve_base_policy.sh',
    '--repo', `${context.repo.owner}/${context.repo.repo}`,
    '--base-ref', pr.base.ref,
    '--base-sha', pr.base.sha,
    '--default-branch', context.payload.repository.default_branch,
    '--default-config', '.github/review-policy.yml',
  ];
  if (shouldMaterializeDefaultPolicy({
    baseRef: pr.base.ref,
    baseSha: pr.base.sha,
    defaultBranch: context.payload.repository.default_branch,
    checkoutSha,
  })) {
    policyResolverArgs.push('--materialize-default');
  }
  policyConfigPath = (await execFileAsync(
    'bash',
    policyResolverArgs,
    {encoding: 'utf8', env: process.env}
  )).trim();
  console.log(`Governing review policy: ${policyConfigPath}`);
} catch (e) {
  policyReadFailed = true;
  core.warning(
    `Could not resolve the governing review policy ` +
    `(${e.message}); requiring external review fail-closed rather ` +
    `than judging this PR by the default-branch policy.`
  );
}

let governingIdentities = {reviewers: [], authorIdentity: ''};
if (!policyReadFailed) {
  try {
    governingIdentities = await loadGoverningIdentities(
      pr,
      policyConfigPath,
    );
  } catch (error) {
    core.warning(
      `Could not load live governing identities (${error.message}); ` +
      `exporting an empty reviewer allow-list so approval ` +
      `enforcement fails closed.`,
    );
  }
}

// Exclude lockfiles, minified, and generated files from line count
// to match REVIEW_POLICY.md threshold definition
const excludePatterns = [
  /\.lock$/, /lock\.json$/, /\.min\.js$/, /\.min\.css$/,
  /\.generated\./, /\.g\.dart$/, /\.freezed\.dart$/,
];
const countedFiles = files.filter(
  f => !excludePatterns.some(p => p.test(f.filename))
);
const totalChanges = countedFiles.reduce(
  (sum, f) => sum + f.additions + f.deletions, 0
);

// Convert glob patterns to regex for matching
function globToRegex(pattern) {
  let re = pattern
    .replace(/\./g, '\\.')
    .replace(/\*\*/g, '___GLOBSTAR___')
    .replace(/\*/g, '[^/]*')
    .replace(/___GLOBSTAR___/g, '.*');
  return new RegExp('^' + re + '$');
}

// Both sides of a rename (#763): GitHub reports the destination in
// .filename and the source in .previous_filename, so matching only
// .filename would let a PR move a protected file to an unprotected
// path without tripping this. Same fix as
// external_review_fingerprint.sh, applied to this inline twin.
const touchesProtected = files.some(f =>
  [f.filename, f.previous_filename]
    .filter(Boolean)
    .some(name => protectedPaths.some(p => globToRegex(p).test(name)))
);

// Use >= to match REVIEW_POLICY.md definition
let needsExternal = totalChanges >= threshold || touchesProtected;
let externalReviewFingerprint = '';
let filesPath = '';
const repo = `${context.repo.owner}/${context.repo.repo}`;
if (policyReadFailed) {
  // Base policy unknown — see the fail-closed note above. Skip the
  // helper entirely: running it against the default-branch config
  // is exactly the bypass being closed, and its result would
  // OVERWRITE needsExternal.
  needsExternal = true;
  externalReviewFingerprint = '';
  console.log(
    'External-review fail-closed: base review policy unreadable; ' +
    'requiring review and skipping the fingerprint calculation.'
  );
} else {
  try {
    filesPath = path.join(os.tmpdir(), `mergepath-pr-${pr.number}-files.json`);
    fs.writeFileSync(filesPath, JSON.stringify(files));
    const fingerprintRaw = await execFileAsync(
      'bash',
      [
        'scripts/workflow/external_review_fingerprint.sh',
        '--repo', repo,
        '--pr', String(pr.number),
        '--ref', pr.head.sha,
        '--config', policyConfigPath,
        '--files-json', filesPath,
      ],
      {encoding: 'utf8', env: process.env}
    );
    const fingerprint = JSON.parse(fingerprintRaw);
    needsExternal = Boolean(fingerprint.requires_review);
    externalReviewFingerprint = fingerprint.fingerprint || '';
  } catch (e) {
    core.warning(
      `External-review fingerprint calculation failed; ` +
      `labeling fail-closed (${e.message}).`
    );
    needsExternal = true;
    externalReviewFingerprint = '';
  }
}

// PROPAGATION-LANE-DEFER (#656): same-repo PR workflows can impersonate github-actions[bot].
// Only a fresh byte verification from trusted default-branch code
// can exempt the current pair; comments grant no authority.
let laneVerifiedHead = false;
if (needsExternal && !policyReadFailed) {
  try {
    await execFileAsync('bash', [
      'scripts/workflow/verify-live-propagation.sh',
      `${context.repo.owner}/${context.repo.repo}`,
      String(pr.number), pr.head.sha, pr.base.sha, policyConfigPath,
    ], {input: JSON.stringify(pr), encoding: 'utf8', timeout: 120000});
    laneVerifiedHead = true;
  } catch (e) {
    laneVerifiedHead = false;
    core.warning(`Propagation byte verification did not clear (${e.message}); labeling fail-closed.`);
  }
}

// Export intrinsic threshold/path requiredness separately from
// the then-live force-on result. A carry-forward below can clear
// already-reviewed bytes, but does not turn the PR into Phase 3.
// Only the exact-pair, byte-verified propagation lane has the
// policy's under-threshold-equivalent standing. The approval
// guard recombines the intrinsic output with its own stabilized
// live labels so overlapping add/remove events cannot latch this
// snapshot's mutable force-on state (#1094).
const phase4IntrinsicRequired =
  phase4IntrinsicRequiredForTriage({
    requiresReview: needsExternal,
    laneVerifiedHead,
  });
const phase4Required = phase4RequiredForTriage({
  requiresReview: needsExternal,
  laneVerifiedHead,
  pr,
});

// The C2 write is separable (#2727 3d): addsExternalLabel records the
// decision, and only a mutate call sends it. The trusted consumer classifies
// with mutate false and writes from its own job.
let addsExternalLabel = false;
if (needsExternal && laneVerifiedHead) {
  console.log(
    `Propagation lane already byte-verified head/base ${pr.head.sha}/${pr.base.sha} ` +
    `(github-actions[bot] v2 pair marker present) — skipping ` +
    `needs-external-review add; the lane owns this PR's labeling.`
  );
} else if (needsExternal) {
  let carried = false;
  try {
    if (needsExternal && externalReviewFingerprint && filesPath) {
      const carryRaw = await execFileAsync(
        'bash',
        [
          'scripts/workflow/external_review_carryforward.sh',
          '--repo', repo,
          '--pr', String(pr.number),
          '--head', pr.head.sha,
          '--current-fingerprint', externalReviewFingerprint,
          '--config', policyConfigPath,
          '--files-json', filesPath,
        ],
        {encoding: 'utf8', env: process.env}
      );
      const carry = JSON.parse(carryRaw);
      carried = Boolean(carry.carried);
      if (carried) {
        needsExternal = false;
        console.log(
          `Codex already cleared the same external-review fingerprint ` +
          `on ${carry.source_commit} at ${carry.source_time}; skipping ` +
          `needs-external-review on base-only sync (#705).`
        );
      }
    }
  } catch (e) {
    core.warning(
      `External-review fingerprint carry-forward check failed; ` +
      `labeling fail-closed using threshold/protected-path result (${e.message}).`
    );
  }

  if (!carried && mayMutateLabels && needsExternal) {
    addsExternalLabel = true;
    if (mutate) {
      await retryIdempotentLabelWrite(
        () => github.rest.issues.addLabels({
          owner: context.repo.owner,
          repo: context.repo.repo,
          issue_number: pr.number,
          labels: ['needs-external-review'],
        }),
        {warn: message => core.warning(message)},
      );
    }
  } else if (!mayMutateLabels && needsExternal) {
    console.log(
      `Computed Phase 4 applicability for the ` +
      `${isForceOnLabelEvent ? 'force-on labeled' : 'unlabeled settle'} ` +
      `event without mutating needs-external-review (#620/#1094).`
    );
  }
}

core.setOutput('needs_external', needsExternal.toString());
core.setOutput('phase_4_required', phase4Required.toString());
core.setOutput(
  'phase_4_intrinsic_required',
  phase4IntrinsicRequired.toString(),
);
core.setOutput('classified_head', pr.head.sha);
core.setOutput('classified_base_ref', pr.base.ref);
core.setOutput('classified_base_sha', pr.base.sha);
core.setOutput(
  'reviewers',
  JSON.stringify(governingIdentities.reviewers),
);
core.setOutput(
  'author_identity',
  governingIdentities.authorIdentity,
);
core.setOutput('adds_external_label', addsExternalLabel.toString());
if (policyConfigPath !== '.github/review-policy.yml') {
  try {
    fs.unlinkSync(policyConfigPath);
  } catch (error) {
    if (error && error.code !== 'ENOENT') throw error;
  }
}
}
// END REVIEW TRIAGE IMPLEMENTATION

module.exports = {evaluateReviewTriage};
