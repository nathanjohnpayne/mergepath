#!/usr/bin/env python3
"""Production writer + trusted dispatcher/generation evaluator; fake API only."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HEAD, BASE, SOURCE = 'a' * 40, 'b' * 40, 'c' * 40
URL = 'https://github.com/example/repo/pull/123'
POLICY = '''author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-codex
  - nathanpayne-claude
external_review_threshold: 100
external_review_paths:
  - scripts/**
propagation_prs:
  enabled: false
codex:
  enabled: true
  allow_phase_4b_substitute: true
  require_ci_green: false
  reaction_freshness_window_seconds: 999999999
  external_review_gate:
    enabled: true
'''
STUB = r'''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
state = json.loads((root/'state.json').read_text())
args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
def emit(value): print(json.dumps(value))
head, base, source = 'a'*40, 'b'*40, 'c'*40
url='https://github.com/example/repo/pull/123'
labels=state.get('labels',['needs-external-review'])
if args[:2] == ['pr','merge']:
    with (root/'writes.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
    sys.exit(0)
if args[:2] == ['pr','view']:
    fields=args[args.index('--json')+1]
    if 'mergeStateStatus' in fields:
        print('\n'.join(['CLEAN','MERGEABLE','0',url,head,'nathanjohnpayne',*labels]))
    else:
        calls=(root/'calls.jsonl').read_text().count('"pr", "view"')
        emit(dict(url=url,headRefOid='d'*40 if state.get('head_moves') and calls>2 else head,
                  baseRefOid=base,baseRefName='release' if state.get('nondefault') else 'main',state='OPEN'))
    sys.exit(0)
if not args or args[0]!='api': sys.exit(99)
if 'user' in args: print('nathanjohnpayne'); sys.exit(0)
endpoint=next((a for a in args[1:] if a=='graphql' or a.startswith('repos/')), '')
if endpoint=='graphql':
    if any('reviewThreads' in a for a in args):
        emit({'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':[],'pageInfo':{'hasNextPage':False}}}}}})
    else:
        emit({'data':{'repository':{'pullRequest':dict(url=url,headRefOid=head,
            isMergeQueueEnabled=state.get('queue',False),isInMergeQueue=False)}}})
    sys.exit(0)
if endpoint=='repos/example/repo': emit(dict(full_name='example/repo',default_branch='main')); sys.exit(0)
if endpoint=='repos/example/repo/commits/main': emit({'sha':source}); sys.exit(0)
if endpoint.startswith('repos/example/repo/tarball/'):
    if state.get('archive_fails'): sys.exit(1)
    sys.stdout.buffer.write((root/'source.tar.gz').read_bytes()); sys.exit(0)
if 'contents/.github/review-policy.yml' in endpoint:
    if state.get('policy_fails'): sys.exit(1)
    print((root/'governing-policy.yml').read_text()); sys.exit(0)
if endpoint=='repos/example/repo/pulls/123':
    emit(dict(number=123,head=dict(sha=head,ref='feature/fixture'),
         base=dict(sha=base,ref='release' if state.get('nondefault') else 'main',repo=dict(default_branch='main')),
         body='Authoring-Agent: codex',user=dict(login='nathanjohnpayne'),labels=[dict(name=l) for l in labels],
         additions=1,deletions=0,changed_files=1)); sys.exit(0)
if endpoint.startswith('repos/example/repo/commits/'):
    print('2026-09-14T00:00:00Z'); sys.exit(0)
if endpoint.endswith('/reviews'):
    reviews=[dict(id=1,user=dict(login='nathanpayne-claude'),state='APPROVED',commit_id=head,
                  submitted_at='2026-09-14T00:05:00Z',body='<!-- mergepath-p4b-request-generation: '+json.dumps(state.get('generation',[123]))+' -->')]
    if state.get('disagreement'): reviews.append(dict(id=2,user=dict(login='nathanpayne-codex'),state='CHANGES_REQUESTED',commit_id='d'*40))
    emit([reviews] if '--slurp' in args else reviews); sys.exit(0)
if endpoint.endswith('/issues/123/comments'):
    if state.get('comments_fail'): sys.exit(1)
    emit([dict(id=n,user=dict(login='nathanjohnpayne'),created_at='2026-09-14T00:04:00Z',body='@codex review') for n in state.get('requests',[123,124])]); sys.exit(0)
if endpoint.endswith('/files'): emit([dict(filename='README.md',additions=1,deletions=0,status='modified')]); sys.exit(0)
if endpoint.endswith('/comments') or endpoint.endswith('/timeline') or endpoint.endswith('/reactions'):
    emit([]); sys.exit(0)
print('unexpected API '+repr(args),file=sys.stderr); sys.exit(99)
'''


class WriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        files = ['scripts/merge-clearance-gate.sh', 'scripts/codex-review-check.sh', 'scripts/hooks/gh-pr-guard.sh']
        files += [str(p.relative_to(ROOT)) for d in ('scripts/lib','scripts/workflow') for p in (ROOT/d).rglob('*') if p.is_file() and '__pycache__' not in str(p)]
        cls.archive = io.BytesIO()
        with tarfile.open(fileobj=cls.archive,mode='w:gz') as bundle:
            for name in files:
                bundle.add(ROOT/name,arcname='repo-'+SOURCE[:7]+'/'+name)
            info=tarfile.TarInfo('repo-'+SOURCE[:7]+'/.github/review-policy.yml')
            data=POLICY.encode(); info.size=len(data); bundle.addfile(info,io.BytesIO(data))
        cls.archive=cls.archive.getvalue()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='merge-writer-test-')
        self.path=Path(self.temp.name)
        self.candidate=self.path/'candidate'
        for folder in ('scripts/lib','scripts/workflow'):
            shutil.copytree(ROOT/folder,self.candidate/folder,ignore=shutil.ignore_patterns('__pycache__'))
        for name in ('scripts/gh-as-author.sh','scripts/identity-check.sh','scripts/merge-clearance-gate.sh','scripts/codex-review-check.sh'):
            shutil.copy2(ROOT/name,self.candidate/name)
        (self.candidate/'.github').mkdir()
        # Candidate policy/checker helpers would vacuously clear; authoritative
        # evidence and code come from the independent fake default-ref archive.
        (self.candidate/'.github/review-policy.yml').write_text('author_identity: nathanjohnpayne\ncodex:\n  enabled: false\n')
        (self.candidate/'scripts/merge-clearance-gate.sh').write_text('#!/bin/bash\nexit 0\n')
        (self.candidate/'scripts/codex-review-check.sh').write_text('#!/bin/bash\nexit 0\n')
        (self.path/'bin').mkdir()
        (self.path/'bin/gh').write_text(STUB); (self.path/'bin/gh').chmod(0o755)
        (self.path/'source.tar.gz').write_bytes(self.archive)
        (self.path/'governing-policy.yml').write_text(POLICY)
        self.state={}

    def tearDown(self):
        self.temp.cleanup()

    def run_writer(self,args=None,**overrides):
        (self.path/'state.json').write_text(json.dumps(self.state))
        env={k:v for k,v in os.environ.items() if not k.startswith(('GH_','GITHUB_','OP_PREFLIGHT_','MERGEPATH_','MERGE_CLEARANCE_','CODEX_REVIEW_','GIT_','BASH_','PYTHON','NODE_','BREAK_GLASS_')) and k not in ('ENV','CODEX_CLEARED')}
        env.update(PATH=str(self.path/'bin')+os.pathsep+env['PATH'], OP_PREFLIGHT_AUTHOR_PAT='ghp_fixture-author',
                   GH_AS_AUTHOR_TRACE_MARKER=str(self.path/'trace'), CODEX_CLEARED='1', **overrides)
        argv=args if args is not None else ['pr','merge','123','--squash','--match-head-commit',HEAD]
        return subprocess.run(['/bin/bash',str(self.candidate/'scripts/gh-as-author.sh'),'--','gh',*argv],
                              env=env,cwd=self.candidate,text=True,capture_output=True,timeout=40)

    def assert_blocked(self,result,reason=None):
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        if reason: self.assertIn(reason,result.stderr)
        self.assertFalse((self.path/'trace').exists())
        self.assertFalse((self.path/'writes.jsonl').exists())
        if (self.path/'calls.jsonl').exists():
            calls=[json.loads(line) for line in (self.path/'calls.jsonl').read_text().splitlines()]
            self.assertFalse(any(call and call[0]=='api' and any(value in ('POST','PATCH','PUT','DELETE') for value in call) for call in calls))

    def test_stale_green_claim_and_candidate_poison_do_not_authorize(self):
        self.assert_blocked(self.run_writer(), 'outside the request generation')

    def test_current_generation_reaches_exactly_one_canonical_writer(self):
        self.state['generation']=[123,124]
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue((self.path/'trace').exists())
        writes=(self.path/'writes.jsonl').read_text().splitlines()
        self.assertEqual(len(writes),1)
        self.assertEqual(json.loads(writes[0])[:5],['pr','merge',URL,'--repo','example/repo'])

    def test_caller_bypass_knobs_cannot_select_gate_semantics(self):
        self.assert_blocked(self.run_writer(MERGE_CLEARANCE_CODEX_CHECK_BIN='/bin/true',
                MERGE_CLEARANCE_WORKFLOW_DIR='/absent',MERGEPATH_REVIEW_POLICY_PATH='/dev/null',
                CODEX_REVIEW_CHECK_SKIP_CI='1',CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE='false'),
                'outside the request generation')

    def test_unreadable_final_generation_refuses_without_trace(self):
        self.state['comments_fail']=True
        self.assert_blocked(self.run_writer())

    def test_archive_and_governing_policy_failure_refuse(self):
        for key in ('archive_fails','policy_fails'):
            self.state={key:True}
            self.assert_blocked(self.run_writer())

    def test_unique_matching_full_head_is_required(self):
        for heads in ([],['d'*40],[HEAD,HEAD],['aaaaaaa']):
            with self.subTest(heads=heads):
                args=['pr','merge','123','--squash']
                for value in heads: args+=['--match-head-commit',value]
                self.assert_blocked(self.run_writer(args),'exactly one matching full')

    def test_explicit_empty_target_is_not_normalized_to_current_branch(self):
        for args in (['pr','merge',''],['pr','merge','123','--repo=']):
            self.assert_blocked(self.run_writer(args+['--match-head-commit',HEAD]), 'explicitly empty')

    def test_under_threshold_does_not_require_external_clearance(self):
        self.state['labels']=[]
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_base_policy_and_target_drift(self):
        self.state.update(generation=[123,124],nondefault=True)
        self.assertEqual(self.run_writer().returncode,0)
        calls=[json.loads(line) for line in (self.path/'calls.jsonl').read_text().splitlines()]
        self.assertTrue(any('contents/.github/review-policy.yml?ref='+BASE in ' '.join(call) for call in calls))
        (self.path/'trace').unlink(); (self.path/'writes.jsonl').unlink()
        (self.path/'calls.jsonl').unlink()
        self.state['head_moves']=True
        self.assert_blocked(self.run_writer(),'changed during final clearance')

    def test_repository_locations_selectors_and_option_values(self):
        variants=[['-Rexample/repo','pr','merge','123'],['pr','-Rexample/repo','merge','branch'],
                  ['pr','merge',URL,'--repo=example/repo'],['pr','merge','-R','example/repo'],
                  ['pr','merge','123','--subject','--admin','--admin=false','--disable-auto=false']]
        self.state['generation']=[123,124]
        for args in variants:
            with self.subTest(args=args):
                result=self.run_writer(args+['--squash','--match-head-commit='+HEAD], GH_REPO='example/repo')
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_holds_disagreement_and_native_queue_remain_blocking(self):
        for state in ({'labels':['human-hold']},{'labels':['policy-violation']},
                      {'labels':['needs-human-review']},{'disagreement':True},{'queue':True}):
            self.state={'generation':[123,124],**state}
            self.assert_blocked(self.run_writer())

    def test_deferred_auto_refused_and_retraction_unchanged(self):
        self.assert_blocked(self.run_writer(['pr','merge','123','--auto']),'deferred auto-merge')
        result=self.run_writer(['pr','merge','123','--disable-auto'])
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in (self.path/'calls.jsonl').read_text().splitlines()]
        self.assertFalse(any('tarball/' in ' '.join(call) for call in calls))

    def test_missing_or_unsafe_closure_refuses(self):
        with tarfile.open(self.path/'source.tar.gz','w:gz') as bundle:
            info=tarfile.TarInfo('repo/scripts/merge-clearance-gate.sh'); info.type=tarfile.SYMTYPE; info.linkname='/bin/true'
            bundle.addfile(info)
        self.assert_blocked(self.run_writer(),'unique regular archive entries')

    def test_removing_fresh_writer_call_is_detected(self):
        wrapper=self.candidate/'scripts/gh-as-author.sh'
        source=wrapper.read_text()
        source=source.replace('python3 "$ROOT/scripts/workflow/merge-writer.py" "$TRACE_MARKER" "$@"','"$@"')
        self.assertNotEqual(source,wrapper.read_text())
        wrapper.write_text(source)
        result=self.run_writer()
        # The stale-request assertion above would fail this mutant: its writer
        # ran despite the uncovered generation, proving discrimination.
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.path/'writes.jsonl').exists())


if __name__=='__main__':
    unittest.main()
