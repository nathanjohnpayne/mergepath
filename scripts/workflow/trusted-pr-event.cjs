'use strict';

// Trusted-default-branch entrypoint. Payload titles identify a candidate; the
// repository/run/review APIs independently bind it before any authority token
// is acquired. Candidate artifacts and candidate source files are never loaded.
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value > 0;
function requireProof(proof, message) {
  if (!proof) throw new Error(`trusted-pr-event: ${message}`);
}
function validatePr(pr, repository, number) {
  requireProof(integer(number) && pr.number === number && pr.state === 'open', 'PR is not the named open candidate');
  requireProof(pr.base?.repo?.id === repository.id && pr.base.repo.full_name === repository.full_name,
    'candidate base repository does not match the trusted repository');
  requireProof(sha(pr.head?.sha) && sha(pr.base?.sha) && integer(pr.head?.repo?.id) &&
    typeof pr.head.ref === 'string' && typeof pr.base.ref === 'string' && typeof pr.user?.login === 'string',
  'candidate metadata is incomplete');
}
async function bindTarget({github, context}) {
  requireProof(context.eventName === 'pull_request_target', 'expected trusted pull_request_target');
  const repository = context.payload.repository;
  const eventPr = context.payload.pull_request;
  requireProof(integer(repository?.id) && repository.full_name === `${context.repo.owner}/${context.repo.repo}`,
    'invalid trusted repository');
  requireProof(integer(eventPr?.number), 'missing candidate number');
  const {data: live} = await github.rest.pulls.get({...context.repo, pull_number: eventPr.number});
  validatePr(live, repository, eventPr.number);
  validatePr(eventPr, repository, eventPr.number);
  for (const [name, before, after] of [
    ['head', eventPr.head.sha, live.head.sha], ['base', eventPr.base.sha, live.base.sha],
    ['base ref', eventPr.base.ref, live.base.ref], ['head repository', eventPr.head.repo.id, live.head.repo.id],
    ['author', eventPr.user.login, live.user.login],
  ]) requireProof(before === after, `${name} changed; refusing a stale mutation batch`);
  return {eventName: 'pull_request', payload: {...context.payload, pull_request: live}};
}
async function bindReviewRun({github, context}) {
  requireProof(context.eventName === 'workflow_run', 'expected trusted workflow_run');
  const repository = context.payload.repository;
  const eventRun = context.payload.workflow_run;
  requireProof(integer(repository?.id) && repository.full_name === `${context.repo.owner}/${context.repo.repo}` &&
    integer(eventRun?.id), 'invalid source envelope');
  const {data: run} = await github.rest.actions.getWorkflowRun({...context.repo, run_id: eventRun.id});
  requireProof(run.id === eventRun.id && run.repository?.id === repository.id &&
    run.repository.full_name === repository.full_name && run.event === 'pull_request_review' &&
    run.status === 'completed' && run.path === '.github/workflows/agent-review-events.yml',
  'source run is not the expected review-event producer');
  const match = /^review-v1 pr=([1-9][0-9]*) review=([1-9][0-9]*) head=([a-f0-9]{40}) base=([a-f0-9]{40})$/.exec(run.display_title);
  requireProof(match && sha(run.head_sha), 'source run has no immutable candidate tuple');
  const number = Number(match[1]);
  const reviewId = Number(match[2]);
  requireProof(integer(number) && integer(reviewId), 'source ids are not positive safe integers');
  const {data: pr} = await github.rest.pulls.get({...context.repo, pull_number: number});
  validatePr(pr, repository, number);
  requireProof(run.head_repository?.id === pr.head.repo.id && run.head_branch === pr.head.ref,
    'source head repository or branch differs from candidate');
  const {data: review} = await github.rest.pulls.getReview({...context.repo, pull_number: number, review_id: reviewId});
  requireProof(review.id === reviewId && review.commit_id === match[3] && integer(review.user?.id) &&
    ['APPROVED', 'CHANGES_REQUESTED', 'COMMENTED', 'DISMISSED'].includes(review.state),
  'source review does not bind the claimed candidate head');
  // Review runs can expose the original PR head directly or a merge ref.
  // Validate whichever immutable source shape the API actually reports. A
  // caller-controlled title never supplies the governing base policy.
  if (run.head_sha === match[3]) {
    requireProof(match[4] === pr.base.sha, 'direct-head source has a stale or substituted base hint');
  } else {
    const {data: commit} = await github.rest.git.getCommit({...context.repo, commit_sha: run.head_sha});
    requireProof(commit.sha === run.head_sha && Array.isArray(commit.parents) && commit.parents.length === 2 &&
      commit.parents[0].sha === match[4] && commit.parents[1].sha === match[3],
    'source merge commit does not bind the claimed head/base pair');
  }
  requireProof(typeof run.created_at === 'string' && typeof review.submitted_at === 'string' &&
    Date.parse(run.created_at) >= Date.parse(review.submitted_at) && Date.parse(run.created_at) >= Date.parse(pr.created_at),
  'source predates the review or candidate');
  // Preserve a delayed review's original head so the existing durable-approval
  // fallback can dismiss an ineligible stale approval. Its guard independently
  // reads current PR/review state and does not persist stale attribution.
  const eventPr = {...pr, head: {...pr.head, sha: match[3]}, base: {...pr.base}};
  return {eventName: 'pull_request_review', payload: {repository, pull_request: eventPr,
    action: 'submitted', review: {...review, state: review.state.toLowerCase()}}};
}
async function bind({github, context, core}) {
  const result = context.eventName === 'pull_request_target'
    ? await bindTarget({github, context}) : await bindReviewRun({github, context});
  core.setOutput('event', JSON.stringify(result.payload));
  core.setOutput('event_name', result.eventName);
  return result;
}
module.exports = {bindTarget, bindReviewRun, bind};
