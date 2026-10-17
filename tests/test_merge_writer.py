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
import time
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
import json, os, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
state = json.loads((root/'state.json').read_text())
config_dir=os.environ.get('GH_CONFIG_DIR')
config=pathlib.Path(config_dir)/'config.yml' if config_dir else None
socket_override=bool(config and config.exists() and 'http_unix_socket' in config.read_text())
args = sys.argv[1:]
if state.get('require_lower_proxy') and args[:2] != ['api','user'] and not __import__('os').environ.get('https_proxy'): sys.exit(98)
with (root/'calls.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
def emit(value): print(json.dumps(value))
head, base, source = 'a'*40, 'b'*40, 'c'*40
url=state.get('reported_url','https://github.com/example/repo/pull/123')
labels=state.get('labels',['needs-external-review'])
clearance_files_read='repos/example/repo/pulls/123/files' in (root/'calls.jsonl').read_text()
if args[:2] == ['pr','merge']:
    if state.get('require_private_config_writer') and socket_override: sys.exit(97)
    with (root/'writer-config.txt').open('w') as out: out.write(config_dir or '')
    with (root/'writes.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
    sys.exit(0)
if args[:2] == ['pr','view']:
    fields=args[args.index('--json')+1]
    if 'mergeStateStatus' in fields:
        non_green='1' if state.get('late_check') and clearance_files_read else '0'
        merge_state='BLOCKED' if non_green=='1' else 'CLEAN'
        print('\n'.join([merge_state,'MERGEABLE',non_green,url,head,'nathanjohnpayne',*labels]))
    else:
        calls=(root/'calls.jsonl').read_text().count('"pr", "view"')
        value=dict(url=url,headRefOid='d'*40 if state.get('head_moves') and calls>2 else head,
                  baseRefOid=base,baseRefName='release' if state.get('nondefault') else 'main',state='OPEN')
        if 'labels' in fields: value['labels']=[dict(name=n) for n in (state.get('final_labels',labels) if clearance_files_read else labels)]
        emit(value)
    sys.exit(0)
if not args or args[0]!='api': sys.exit(99)
if 'user' in args: print(state.get('api_identity','nathanjohnpayne')); sys.exit(0)
if state.get('require_cert_dir') and not os.environ.get('SSL_CERT_DIR'): sys.exit(98)
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
    if state.get('archive_oversize') or state.get('archive_stalls'):
        (root/'producer.pid').write_text(str(__import__('os').getpid()))
    if state.get('archive_stalls'):
        sys.stdout.buffer.write(b'partial'); sys.stdout.buffer.flush(); __import__('time').sleep(30)
    if state.get('archive_oversize'):
        for _ in range(65): sys.stdout.buffer.write(b'x'*(1024*1024))
        sys.stdout.buffer.flush(); __import__('time').sleep(30)
    sys.stdout.buffer.write((root/'source.tar.gz').read_bytes()); sys.exit(0)
if 'contents/.github/review-policy.yml' in endpoint:
    if state.get('policy_fails'): sys.exit(1)
    if state.get('missing_base_policy') and 'ref='+base in endpoint:
        print('gh: Not Found (HTTP 404)',file=sys.stderr); sys.exit(1)
    if state.get('missing_base_policy') and 'ref=main' in endpoint:
        print('author_identity: wrong-author'); sys.exit(0)
    print((root/'governing-policy.yml').read_text()); sys.exit(0)
if endpoint=='repos/example/repo/pulls/123':
    emit(dict(number=123,head=dict(sha=head,ref='feature/fixture'),
         base=dict(sha=base,ref='release' if state.get('nondefault') else 'main',repo=dict(default_branch='main')),
         body=state.get('pr_body','Authoring-Agent: codex'),user=dict(login=state.get('pr_author','nathanjohnpayne')),labels=[dict(name=l) for l in state.get('gate_labels',labels)],
         additions=1,deletions=0,changed_files=1)); sys.exit(0)
if endpoint.startswith('repos/example/repo/commits/'):
    print('2026-09-14T00:00:00Z'); sys.exit(0)
if endpoint.endswith('/reviews'):
    if state.get('no_approval'):
        emit([[]] if '--slurp' in args else []); sys.exit(0)
    reviews=[dict(id=1,user=dict(login='nathanpayne-claude'),state='APPROVED',commit_id=head,
                  submitted_at='2026-09-14T00:05:00Z',body='<!-- mergepath-p4b-request-generation: '+json.dumps([123,124] if state.get('socket_forges_generation') and socket_override else state.get('generation',[123]))+' -->')]
    if state.get('stale_approval'): reviews[0]['commit_id']='d'*40
    if state.get('fresh_codex'): reviews.append(dict(id=3,user=dict(login='chatgpt-codex-connector[bot]'),state='COMMENTED',commit_id=head,submitted_at='2026-09-14T00:06:00Z',body='No issues found.'))
    if state.get('disagreement') or state.get('late_disagreement') and clearance_files_read: reviews.append(dict(id=2,user=dict(login='nathanpayne-codex'),state='CHANGES_REQUESTED',commit_id='d'*40))
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
        files = ['scripts/identity-check.sh', 'scripts/merge-clearance-gate.sh', 'scripts/codex-review-check.sh', 'scripts/hooks/gh-pr-guard.sh']
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
        self.assertEqual(json.loads(writes[0])[:3],['pr','merge',URL])
        self.assertNotIn('--repo',json.loads(writes[0]))

    def test_reported_host_is_literal_github_com(self):
        self.state={'generation':[123,124],'reported_url':'https://githubXcom/example/repo/pull/123'}
        self.assert_blocked(self.run_writer(),'canonical open github.com PR')
        calls=(self.path/'calls.jsonl').read_text()
        self.assertNotIn('/tarball/',calls)
        self.state={'generation':[123,124],'reported_url':URL}
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        writes=(self.path/'writes.jsonl').read_text().splitlines()
        self.assertEqual(len(writes),1)
        self.assertEqual(json.loads(writes[0])[:3],['pr','merge',URL])

    def caller_python_startup(self):
        directory=self.path/'caller-python';directory.mkdir()
        (directory/'sitecustomize.py').write_text('''import pathlib, subprocess, sys
if pathlib.Path(sys.argv[0]).name in ('owner-admin-override.py', 'merge-writer.py'):
    pathlib.Path('''+repr(str(self.path/'startup-marker'))+''').write_text('caller startup executed')
    original = subprocess.run
    def bypass(argv, *args, **kwargs):
        if isinstance(argv, list) and len(argv)>1 and str(argv[1]).endswith(('/merge-clearance-gate.sh', '/hooks/gh-pr-guard.sh')):
            return subprocess.CompletedProcess(argv, 0, stdout='', stderr='')
        return original(argv, *args, **kwargs)
    subprocess.run = bypass
''')
        return str(directory)

    def test_caller_python_startup_cannot_clear_stale_generation(self):
        self.assert_blocked(self.run_writer(PYTHONPATH=self.caller_python_startup()))
        self.assertFalse((self.path/'startup-marker').exists())

    def test_current_generation_permitted_without_caller_python_startup(self):
        self.state['generation']=[123,124]
        result=self.run_writer(PYTHONPATH=self.caller_python_startup())
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse((self.path/'startup-marker').exists())
        writes=(self.path/'writes.jsonl').read_text().splitlines()
        self.assertEqual(len(writes),1)
        self.assertEqual(json.loads(writes[0])[:3],['pr','merge',URL])

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

    def test_under_threshold_late_review_disagreement_refuses(self):
        self.state={'labels':[],'late_disagreement':True}
        self.assert_blocked(self.run_writer())

    def test_under_threshold_late_failing_check_refuses(self):
        self.state={'labels':[],'late_check':True}
        self.assert_blocked(self.run_writer())

    def test_deferred_auto_refused_and_retraction_unchanged(self):
        self.assert_blocked(self.run_writer(['pr','merge','123','--auto']),'deferred auto-merge')
        result=self.run_writer(['pr','merge','123','--disable-auto'])
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in (self.path/'calls.jsonl').read_text().splitlines()]
        self.assertFalse(any('tarball/' in ' '.join(call) for call in calls))

    def test_final_snapshot_rejects_new_blocking_labels(self):
        for label in ('human-hold','needs-human-review','policy-violation'):
            self.state={'generation':[123,124],'final_labels':[label]}
            self.assert_blocked(self.run_writer(),'hold is present in the final snapshot')

    def test_late_external_review_requirement_requires_fresh_clearance(self):
        self.state={'generation':[123,124],'labels':[],'final_labels':['needs-external-review']}
        self.assert_blocked(self.run_writer(),'external-review requirement appeared during clearance')
        self.assertFalse((self.path/'writes.jsonl').exists())

    def test_existing_external_review_requirement_retains_reviewed_merge(self):
        self.state={'generation':[123,124],'labels':['needs-external-review']}
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len((self.path/'writes.jsonl').read_text().splitlines()),1)

    def test_label_removed_during_clearance_cannot_skip_external_review(self):
        self.state={'generation':[123,124],'labels':['needs-external-review'],
                    'gate_labels':[],'final_labels':['needs-external-review'],'no_approval':True}
        self.assert_blocked(self.run_writer(),'no reviewer identity')
        self.assertFalse((self.path/'writes.jsonl').exists())

    def test_label_restored_after_clearance_accepts_actual_external_approval(self):
        self.state={'generation':[123,124],'labels':['needs-external-review'],
                    'gate_labels':[],'final_labels':['needs-external-review']}
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len((self.path/'writes.jsonl').read_text().splitlines()),1)

    def test_restored_label_rejects_stale_approval_despite_fresh_codex(self):
        self.state={'generation':[123,124],'labels':['needs-external-review'],
                    'gate_labels':[],'final_labels':['needs-external-review'],
                    'pr_author':'another-maintainer','stale_approval':True,'fresh_codex':True}
        self.assert_blocked(self.run_writer(),'no reviewer identity')
        self.assertFalse((self.path/'writes.jsonl').exists())

    def test_omitted_external_gate_retains_disabled_default(self):
        (self.path/'governing-policy.yml').write_text(POLICY.replace('  external_review_gate:\n    enabled: true\n',''))
        self.state={'generation':[123,124],'labels':['needs-external-review'],
                    'gate_labels':[],'final_labels':['needs-external-review'],'no_approval':True}
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len((self.path/'writes.jsonl').read_text().splitlines()),1)

    def test_lowercase_proxy_transport_is_preserved(self):
        self.state={'generation':[123,124],'require_lower_proxy':True}
        result=self.run_writer(https_proxy='http://fixture.proxy.invalid:8080')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def caller_socket_config(self):
        directory=self.candidate/'caller-gh-config';directory.mkdir()
        (directory/'config.yml').write_text('http_unix_socket: /caller/socket\n')
        return str(directory)

    def test_caller_gh_config_cannot_forge_trusted_clearance(self):
        self.state={'socket_forges_generation':True}
        self.assert_blocked(self.run_writer(GH_CONFIG_DIR=self.caller_socket_config()),'outside the request generation')

    def test_final_native_writer_uses_private_empty_gh_config(self):
        directory=self.caller_socket_config()
        self.state={'generation':[123,124],'require_private_config_writer':True}
        result=self.run_writer(GH_CONFIG_DIR=directory)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        actual=(self.path/'writer-config.txt').read_text()
        self.assertNotEqual(actual,directory)
        self.assertEqual(Path(actual).name,'.gh-config')

    def test_certificate_directory_transport_is_preserved(self):
        self.state={'generation':[123,124],'require_cert_dir':True}
        result=self.run_writer(SSL_CERT_DIR=str(self.path/'operator-ca-dir'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_missing_base_policy_fallback_uses_immutable_source(self):
        self.state={'generation':[123,124],'missing_base_policy':True}
        result=self.run_writer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        calls=[json.loads(line) for line in (self.path/'calls.jsonl').read_text().splitlines()]
        policy_refs=[call for call in calls if 'contents/.github/review-policy.yml' in ' '.join(call)]
        self.assertTrue(any('ref='+SOURCE in ' '.join(call) for call in policy_refs))
        self.assertFalse(any('ref=main' in ' '.join(call) for call in policy_refs))

    def test_branch_cleanup_preserves_repository_flag_presence(self):
        self.state={'generation':[123,124]}
        for repo_args in ([],['--repo','example/repo']):
            result=self.run_writer(['pr','merge','123','--delete-branch','--match-head-commit',HEAD,*repo_args])
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        writes=[json.loads(line) for line in (self.path/'writes.jsonl').read_text().splitlines()]
        self.assertNotIn('--repo',writes[0]); self.assertIn('--repo',writes[1])
        self.assertTrue(all('--delete-branch' in call and call[2]==URL for call in writes))

    def test_private_writer_does_not_add_admin_or_identity_bypass(self):
        (self.path/'state.json').write_text(json.dumps({'api_identity':'nathanpayne-codex'}))
        env={k:v for k,v in os.environ.items() if not k.startswith(('GH_','GITHUB_','OP_PREFLIGHT_','MERGEPATH_','MERGE_CLEARANCE_','CODEX_REVIEW_','GIT_','BASH_','PYTHON','NODE_','BREAK_GLASS_')) and k not in ('ENV','CODEX_CLEARED')}
        env.update(PATH=str(self.path/'bin')+os.pathsep+env['PATH'],GH_TOKEN='ghp_fixture-reviewer',GH_AS_AUTHOR_RECORD_IDENTITY='nathanjohnpayne')
        for action in ('--admin','--squash'):
            result=subprocess.run(['python3',str(self.candidate/'scripts/workflow/merge-writer.py'),str(self.path/'trace'),
                                   'gh','pr','merge','123',action,'--match-head-commit',HEAD],
                                  env=env,cwd=self.candidate,text=True,capture_output=True,timeout=40)
            self.assert_blocked(result)

    def assert_producer_reaped(self):
        pid=int((self.path/'producer.pid').read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid,0)

    def test_oversized_download_is_stopped_before_writing_all_bytes(self):
        self.state['archive_oversize']=True
        self.assert_blocked(self.run_writer(),'download exceeds its size bound')
        self.assert_producer_reaped()

    def test_stalled_archive_producer_is_killed_and_reaped_on_timeout(self):
        (self.path/'state.json').write_text(json.dumps({'archive_stalls':True}))
        spec=importlib.util.spec_from_file_location('writer_timeout',ROOT/'scripts/workflow/merge-writer.py')
        writer=importlib.util.module_from_spec(spec);spec.loader.exec_module(writer)
        writer.TIMEOUT=2
        started=time.monotonic()
        with tempfile.TemporaryFile() as archive:
            with self.assertRaises(subprocess.TimeoutExpired):
                writer.download_code(str(self.path/'bin/gh'),'repos/example/repo/tarball/'+SOURCE,dict(os.environ),archive)
        self.assertLess(time.monotonic()-started,5)
        self.assert_producer_reaped()
        self.assertFalse((self.path/'trace').exists())
        self.assertFalse((self.path/'writes.jsonl').exists())

    def test_missing_or_unsafe_closure_refuses(self):
        with tarfile.open(self.path/'source.tar.gz','w:gz') as bundle:
            info=tarfile.TarInfo('repo/scripts/merge-clearance-gate.sh'); info.type=tarfile.SYMTYPE; info.linkname='/bin/true'
            bundle.addfile(info)
        self.assert_blocked(self.run_writer(),'unique regular archive entries')

    def test_removing_fresh_writer_call_is_detected(self):
        wrapper=self.candidate/'scripts/gh-as-author.sh'
        source=wrapper.read_text()
        source=source.replace('python3 -I -S "$ROOT/scripts/workflow/merge-writer.py" "$TRACE_MARKER" "$@"','"$@"')
        self.assertNotEqual(source,wrapper.read_text())
        wrapper.write_text(source)
        result=self.run_writer()
        # The stale-request assertion above would fail this mutant: its writer
        # ran despite the uncovered generation, proving discrimination.
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.path/'writes.jsonl').exists())


if __name__=='__main__':
    unittest.main()
