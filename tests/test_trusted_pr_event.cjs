'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {bindTarget, bindReviewRun} = require('../scripts/workflow/trusted-pr-event.cjs');
const A = 'a'.repeat(40), B = 'b'.repeat(40), M = 'c'.repeat(40);
function fixture() {
  const repository = {id:1, full_name:'owner/repo', default_branch:'main'};
  const pr = {number:7,state:'open',created_at:'2026-10-14T00:00:00Z',user:{login:'author'},
    head:{sha:A,ref:'feature',repo:{id:2,full_name:'owner/fork',fork:true}},
    base:{sha:B,ref:'main',repo:repository}};
  const review = {id:9,commit_id:A,user:{id:3,login:'reviewer'},state:'APPROVED',submitted_at:'2026-10-14T00:01:00Z'};
  const run = {id:4,repository,head_repository:pr.head.repo,head_branch:'feature',head_sha:M,
    path:'.github/workflows/agent-review-events.yml',event:'pull_request_review',status:'completed',
    display_title:`review-v1 pr=7 review=9 head=${A} base=${B}`,created_at:'2026-10-14T00:02:00Z'};
  const commit = {sha:M,parents:[{sha:B},{sha:A}]};
  const context = {repo:{owner:'owner',repo:'repo'},eventName:'pull_request_target',
    payload:{repository,pull_request:structuredClone(pr),action:'opened'}};
  const reads=[];
  const result = data => async args => { reads.push(args); return {data:structuredClone(data)}; };
  const github = {rest:{pulls:{get:result(pr),getReview:result(review)},
    actions:{getWorkflowRun:result(run)},git:{getCommit:result(commit)}}};
  return {github,context,pr,review,run,commit,reads};
}
// Execute the checked-in disagreement writer, not a test copy of its guards.
const workflowSource = fs.readFileSync(require.resolve('../.github/workflows/agent-review.yml'), 'utf8');
const disagreementStep = workflowSource.split('      - name: Check for conflicting reviews\n')[1]
  .split('\n  # ')[0].split('          script: |\n')[1]
  .split('\n').map(line => line.slice(12)).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const runDisagreementStep = new AsyncFunction('github', 'context', 'core', 'require', 'process', disagreementStep);
async function disagreementFixture({conflict=false, hasLabel=true, mutate, failRead=0}={}) {
  const f=fixture();
  f.context.eventName='workflow_run';
  f.context.payload={repository:f.context.payload.repository,workflow_run:{id:4}};
  f.pr.head.sha='d'.repeat(40);
  const bound=await bindReviewRun(f);
  assert.equal(bound.payload.pull_request.head.sha,A, 'delayed event keeps historical enforcement head');
  const reviews=[{id:10,user:{login:'nathanpayne-codex'},state:'APPROVED',commit_id:f.pr.head.sha,
    submitted_at:'2026-10-14T00:03:00Z'}];
  if (conflict) reviews.push({id:11,user:{login:'nathanpayne-claude'},state:'CHANGES_REQUESTED',
    commit_id:f.pr.head.sha,submitted_at:'2026-10-14T00:04:00Z'});
  const writes=[];
  let liveReads=0;
  f.github.rest.pulls.get=async () => {
    liveReads++;
    if (liveReads===failRead) throw new Error('fake unreadable live pair');
    return {data:structuredClone(f.pr)};
  };
  f.github.paginate=async () => { if (mutate) mutate(f.pr); return reviews; };
  f.github.rest.issues={listLabelsOnIssue:async()=>({data:hasLabel?[{name:'needs-human-review'}]:[]})};
  for (const method of ['addLabels','removeLabel','createComment']) {
    f.github.rest.issues[method]=async args=>{writes.push({method,args});};
  }
  const fakeRequire=name=>name==='js-yaml' ? {load:()=>({available_reviewers:['nathanpayne-codex','nathanpayne-claude']})} : require(name);
  const run=()=>runDisagreementStep(f.github,{repo:f.context.repo},{notice:()=>{}},fakeRequire,
    {env:{GITHUB_WORKSPACE:require('node:path').resolve(__dirname,'..'),
      TRUSTED_EVENT_JSON:JSON.stringify(bound.payload),TRUSTED_EVENT_NAME:bound.eventName}});
  return {run,writes,get liveReads(){return liveReads;}};
}
let passed=0;
async function check(name,fn) { await fn(); passed++; console.log(`PASS ${name}`); }
(async () => {
  await check('target canonical API binding', async () => {
    const f=fixture(); const r=await bindTarget(f); assert.equal(r.eventName,'pull_request');
    assert.deepEqual(r.payload.pull_request,f.pr); assert.equal(f.reads.length,1);
  });
  for (const [name,mutate] of [
    ['head drift',f=>f.pr.head.sha=B],['base drift',f=>f.pr.base.sha=A],
    ['retarget',f=>f.pr.base.ref='release'],['repository substitution',f=>f.pr.base.repo={id:5,full_name:'evil/repo'}],
    ['fork substitution',f=>f.pr.head.repo={id:8}],['author substitution',f=>f.pr.user.login='attacker'],
    ['closed candidate',f=>f.pr.state='closed'],['invalid source event',f=>f.context.eventName='pull_request'],
  ]) await check(`target rejects ${name}`,async()=>{ const f=fixture(); mutate(f); await assert.rejects(bindTarget(f)); });
  function reviewFixture() { const f=fixture(); f.context.eventName='workflow_run'; f.context.payload={repository:f.context.payload.repository,workflow_run:{id:4}}; return f; }
  await check('review API, repository, immutable merge parents and timestamp proof',async()=>{
    const f=reviewFixture(); const r=await bindReviewRun(f); assert.equal(r.eventName,'pull_request_review');
    assert.equal(r.payload.review.state,'approved'); assert.equal(r.payload.pull_request.head.sha,A); assert.equal(f.reads.length,4);
  });
  await check('review source may bind the original PR head directly',async()=>{
    const f=reviewFixture(); f.run.head_sha=A; const r=await bindReviewRun(f);
    assert.equal(r.payload.pull_request.head.sha,A); assert.equal(f.reads.length,3);
  });
  await check('direct source cannot substitute its live governing base',async()=>{
    const f=reviewFixture(); f.run.head_sha=A; f.run.display_title=f.run.display_title.replace(`base=${B}`,`base=${A}`);
    await assert.rejects(bindReviewRun(f));
  });
  await check('historical merge binding never supplies a stale governing base',async()=>{
    const f=reviewFixture(); f.pr.base.sha='e'.repeat(40); const r=await bindReviewRun(f);
    assert.equal(r.payload.pull_request.base.sha,f.pr.base.sha);
  });
  await check('durable delayed approval retains original pair for canonical enforcement',async()=>{
    const f=reviewFixture(); f.pr.head.sha='d'.repeat(40); const r=await bindReviewRun(f); assert.equal(r.payload.pull_request.head.sha,A);
  });
  for (const [name,mutate] of [
    ['workflow substitution',f=>f.run.path='.github/workflows/malicious.yml'],
    ['other trigger',f=>f.run.event='push'],['foreign run',f=>f.run.repository={id:9}],
    ['foreign fork',f=>f.run.head_repository={id:9}],['branch mismatch',f=>f.run.head_branch='evil'],
    ['PR hint substitution',f=>f.run.display_title=f.run.display_title.replace('pr=7','pr=8')],
    ['review hint substitution',f=>f.run.display_title=f.run.display_title.replace('review=9','review=8')],
    ['head hint substitution',f=>f.run.display_title=f.run.display_title.replace(`head=${A}`,`head=${B}`)],
    ['base hint substitution',f=>f.run.display_title=f.run.display_title.replace(`base=${B}`,`base=${A}`)],
    ['source unrelated to merge tuple',f=>f.commit.parents=[{sha:A},{sha:B}]],
    ['source timestamp replay',f=>f.run.created_at='2026-10-13T23:00:00Z'],
    ['missing source',f=>f.run.status='in_progress'],['malformed SHA',f=>f.run.head_sha='main'],
    ['unsafe integer id',f=>f.run.display_title=f.run.display_title.replace('review=9','review=9999999999999999999999')],
    ['malformed review identity',f=>f.review.user.id=null],['candidate shell text',f=>f.run.display_title+='; echo SECRET'],
  ]) await check(`review rejects ${name}`,async()=>{ const f=reviewFixture(); mutate(f); await assert.rejects(bindReviewRun(f)); });
  await check('candidate workflow/helper/package bytes cannot be loaded by authority binding',async()=>{
    const f=reviewFixture();
    // No artifact, checkout, package install, filesystem read, eval or mutation API
    // is supplied. A malicious candidate has only inert hint fields to influence.
    f.run.artifacts_url='candidate-controlled'; f.pr.body='$(touch /tmp/not-executed)';
    await bindReviewRun(f); assert.equal(f.reads.length,4);
    const source=fs.readFileSync(require.resolve('../scripts/workflow/trusted-pr-event.cjs'),'utf8');
    const denied = new Proxy({}, {get(){throw new Error('candidate code/credential access');}});
    const sandbox={module:{exports:{}},require(){throw new Error('filesystem/packages forbidden');},process:denied};
    vm.runInNewContext(source,sandbox);
    await sandbox.module.exports.bindReviewRun(f);
  });
  await check('delayed historical review preserves the live-head disagreement hold',async()=>{
    const f=await disagreementFixture({conflict:true}); await f.run();
    assert.deepEqual(f.writes,[]); assert.equal(f.liveReads,1);
  });
  await check('delayed historical review still applies a missing live-head disagreement hold',async()=>{
    const f=await disagreementFixture({conflict:true,hasLabel:false}); await f.run();
    assert.deepEqual(f.writes.map(w=>w.method),['addLabels','createComment']); assert.equal(f.liveReads,2);
  });
  await check('stable live-head agreement retains the disagreement hold for human release',async()=>{
    const f=await disagreementFixture(); await f.run();
    assert.deepEqual(f.writes,[]);
  });
  await check('stable live-head agreement without a hold makes no write',async()=>{
    const f=await disagreementFixture({hasLabel:false}); await f.run(); assert.deepEqual(f.writes,[]);
  });
  for (const [name,mutate] of [
    ['head drift',pr=>pr.head.sha='e'.repeat(40)],
    ['base drift',pr=>pr.base.sha='f'.repeat(40)],
    ['base retarget',pr=>pr.base.ref='release'],
  ]) for (const apply of [false,true]) await check(`disagreement ${apply?'application fenced':'hold retained'} on ${name}`,async()=>{
    const f=await disagreementFixture({conflict:apply,hasLabel:!apply,mutate}); await f.run();
    assert.deepEqual(f.writes,[]); if (apply) assert.equal(f.liveReads,2);
  });
  for (const failRead of [1,2]) await check(`disagreement fails closed on unreadable live pair at read ${failRead}`,async()=>{
    const f=await disagreementFixture({conflict:true,hasLabel:false,failRead}); await assert.rejects(f.run(),/unreadable live pair/);
    assert.deepEqual(f.writes,[]);
  });
  for (const [name,mutate] of [
    ['malformed head',pr=>pr.head.sha='main'],['malformed base',pr=>pr.base.sha='main'],
    ['foreign base repository',pr=>pr.base.repo.full_name='evil/repo'],['closed PR',pr=>pr.state='closed'],
  ]) await check(`disagreement writer rejects ${name}`,async()=>{
    const f=await disagreementFixture({conflict:true,hasLabel:false,mutate}); await assert.rejects(f.run(),/Unreadable live PR head\/base/);
    assert.deepEqual(f.writes,[]);
  });
  console.log(`${passed} tests passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});
