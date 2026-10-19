#!/usr/bin/env python3
"""Exercise the actual admin writer preparation and audit record parser."""
import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import runpy
import contextlib
import io
import sys

# Import the real helper without generating binary artifacts in scripts/,
# which the repository's standing text checks inspect.
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/workflow/owner-admin-override.py'
spec = importlib.util.spec_from_file_location('override', SCRIPT)
override = importlib.util.module_from_spec(spec)
spec.loader.exec_module(override)
URL = 'https://github.com/example/repo/pull/123'
HEAD = 'a' * 40
AUTH = {'version': 1, 'pr_url': URL, 'head_sha': HEAD, 'authorized_at': '2026-01-01T00:00:00Z',
        'authorization_quote': 'Admin merge this exact PR and head.', 'allow_needs_human_review': False,
        'allow_codex_inflight': False}


def check_run(identity, name='lint', conclusion='SUCCESS', *, status='COMPLETED', producer='actions'):
    return {'__typename': 'CheckRun', 'id': str(identity), 'name': name, 'status': status,
            'conclusion': conclusion, 'startedAt': '2026-01-01T00:00:00Z',
            'completedAt': '2026-01-01T00:01:00Z' if status == 'COMPLETED' else None,
            'checkSuite': {'id': 'suite-' + str(identity), 'app': {'id': producer}}}


def commit_status(identity, name='legacy-ci', state='SUCCESS', *, producer='legacy'):
    return {'__typename': 'StatusContext', 'id': str(identity), 'context': name, 'state': state,
            'createdAt': '2026-01-01T00:00:00Z', 'updatedAt': '2026-01-01T00:01:00Z',
            'creator': {'login': producer}}


def inventory_pages(pr, checks, size=100):
    counts = {'totalCount': len(checks), 'checkRunCount': sum(c['__typename'] == 'CheckRun' for c in checks),
              'statusContextCount': sum(c['__typename'] == 'StatusContext' for c in checks)}
    chunks = [checks[index:index + size] for index in range(0, len(checks), size)] or [[]]
    return [{'data': {'repository': {'pullRequest': {key: pr[key] for key in override.PR_FIELDS.split(',')},
                                    'object': {'oid': HEAD, 'statusCheckRollup': {'contexts': {
                                        **counts, 'nodes': chunk, 'pageInfo': {
                                            'hasNextPage': index + 1 < len(chunks),
                                            'endCursor': f'page-{index + 1}' if chunk else None}}}}}}}
            for index, chunk in enumerate(chunks)]


def completion_fixture(*, requests=None, replies=False, response_time='2026-01-01T00:00:02Z'):
    request = {'id': 801, 'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review',
               'created_at': '2026-01-01T00:00:01Z'}
    requests = requests or [request]
    review = {'id': 901, 'user': {'login': override.BOT}, 'body': '' if replies else 'Completed review',
              'commit_id': 'b' * 40, 'submitted_at': response_time}
    inputs = {'pr': 123, 'repo': 'example/repo', 'head_sha': HEAD, 'author': 'nathanjohnpayne',
              'bot': override.BOT, 'required_tiers': ['p0', 'p1'],
              'requests': [{'id': row['id'], 'created_at': row['created_at'], 'counted': True,
                            'source': 'issue', 'author': 'nathanjohnpayne', 'eyes_at': None} for row in requests],
              'reviews': [{'id': 901, 'submitted_at': response_time, 'commit_id': 'b' * 40,
                           'body_tiers': [], 'root_findings': [], 'reply_comments': int(replies), 'reply_markers': []}],
              'verdicts': [], 'blocks': [], 'rebuttals': [], 'summary': None}
    result = subprocess.run(['bash', '-c', '. "$1"; crl_ledger "$(cat)"', '_',
                             str(ROOT / 'scripts/lib/codex-review-ledger.sh')],
                            input=json.dumps(inputs), text=True, capture_output=True, check=True, timeout=30)
    return requests, [review], json.loads(result.stdout)


class OverrideTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.state = {'pr': {'url': URL, 'headRefOid': HEAD, 'baseRefOid': 'b' * 40,
                            'baseRefName': 'main', 'state': 'OPEN', 'labels': []},
                      'comments': [], 'reviews': [], 'timeline': []}
        self.state['inventory_pages'] = inventory_pages(self.state['pr'], [check_run('gate', 'Merge clearance gate', 'FAILURE')])
        stub = self.path / 'gh'
        stub.write_text('''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
p=Path(os.environ['OVERRIDE_CASE']); s=json.loads((p/'state.json').read_text()); a=sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['api','user']:
 print(s.get('identity','nathanjohnpayne')); sys.exit(0)
elif a[:2]==['pr','merge']:
 (p/'merged.json').write_text(json.dumps(a)); sys.exit(0)
elif a[:2]==['pr','view']:
 result=s['pr'].copy()
 counter=p/'pr-reads'; read=int(counter.read_text())+1 if counter.exists() else 1; counter.write_text(str(read))
 result.update(s.get('pr_read_changes',{}).get(str(read),{}))
 if (p/'posted.json').exists() and s.get('move'): result['headRefOid']='b'*40
 if (p/'posted.json').exists() and s.get('late_label'): result['labels']=[{'name':s['late_label']}]
elif a[0]=='api' and '/contents/.github/review-policy.yml?ref=' in a[1]:
 result={'encoding':'base64','content':base64.b64encode(json.dumps(s.get('policy',{})).encode()).decode()}
elif a[:2]==['api','graphql']:
 cursor=next(value[7:] for value in a if value.startswith('cursor='))
 page=0 if cursor=='null' else int(cursor.split('-')[1])
 counter=p/'inventory-round'
 round=int(counter.read_text()) if counter.exists() else 0
 if cursor=='null':
  round+=1; counter.write_text(str(round))
 inventories=s.get('inventory_passes',[s['inventory_pages']])
 pages=inventories[min(round-1,len(inventories)-1)]
 if s.get('inventory_fail_page')==page or page>=len(pages): sys.exit(8)
 if (p/'posted.json').exists() and s.get('inventory_fail_after_post'): sys.exit(8)
 result=pages[page]
 if s.get('page_pr_change') and page==1:
  result['data']['repository']['pullRequest'].update(s['page_pr_change'])
 if (p/'posted.json').exists() and s.get('post_inventory_change'):
  result['data']['repository']['object']['statusCheckRollup']['contexts']['nodes'][0]['conclusion']='SUCCESS'
elif a[:3]==['api','--paginate','--slurp']:
 suffix=a[3].split('/')[-1]; result=[s.get('inline' if '/pulls/' in a[3] and suffix=='comments' else suffix,[])]
 if (p/'posted.json').exists() and s.get('late_codex') and '/issues/' in a[3] and suffix=='comments':
  result=[[*result[0],{'user':{'login':'nathanjohnpayne'},'body':'@codex review','created_at':'2026-01-01T00:01:01Z'}]]
 if s.get('prepost_codex') and (p/'inventory-round').exists() and int((p/'inventory-round').read_text())>=2 and '/issues/' in a[3] and suffix=='comments':
  result=[[*result[0],{'user':{'login':'nathanjohnpayne'},'body':'@codex review','created_at':'2026-01-01T00:01:01Z'}]]
 if suffix=='timeline' and ((s.get('late_escalation') and (p/'posted.json').exists()) or
    (s.get('prepost_escalation') and (p/'inventory-round').exists() and int((p/'inventory-round').read_text())>=2)):
  result=[[*result[0],{'event':'labeled','label':{'name':'needs-human-review'},'created_at':'2026-01-01T00:01:01Z'}]]
elif a[0]=='api' and '/issues/comments/' in a[1]:
 result=json.loads((p/'posted.json').read_text())
elif a[0]=='api' and a[1].endswith('/comments') and '-f' in a:
 body=a[a.index('-f')+1][5:]; result={'id':77,'body':body,'user':{'login':'nathanjohnpayne'},'created_at':'2026-01-01T00:01:00Z','updated_at':'2026-01-01T00:01:00Z','html_url':'https://github.com/example/repo/pull/123#issuecomment-77'}
 if s.get('bad_readback'): result['user']['login']='wrong-account'
 (p/'posted.json').write_text(json.dumps(result))
else: sys.exit(9)
print(json.dumps(result))
''')
        stub.chmod(0o755)

    def run_prepare(self, record=None, args=None, pin=None, *, mode='prepare', wrapper=False, inprocess=False):
        (self.path / 'state.json').write_text(json.dumps(self.state))
        for counter in ('inventory-round', 'pr-reads', 'calls'):
            (self.path / counter).unlink(missing_ok=True)
        env = {**os.environ, 'PATH': str(self.path) + os.pathsep + os.environ['PATH'],
               'OVERRIDE_CASE': str(self.path), 'GH_AS_AUTHOR_RECORD_IDENTITY': 'nathanjohnpayne',
               'BREAK_GLASS_ADMIN': pin or URL + '@' + HEAD,
               'MERGEPATH_OWNER_ADMIN_AUTHORIZATION': json.dumps(record or AUTH)}
        for key in ('GH_TOKEN', 'GITHUB_TOKEN', 'OP_PREFLIGHT_AUTHOR_PAT', 'OP_PREFLIGHT_REVIEWER_PAT'):
            env.pop(key, None)
        env['OP_PREFLIGHT_CACHE_DIR'] = str(self.path / 'cache')
        command = ['python3', str(SCRIPT), mode]
        if wrapper:
            command = ['bash', str(self.path / 'wrapper/scripts/gh-as-author.sh'), '--']
            env.update(OP_PREFLIGHT_AUTHOR_PAT='ghp_fixture', GH_AS_AUTHOR_IDENTITY='nathanjohnpayne',
                       MERGEPATH_GH_TRANSPORT='gh',
                       GH_AS_AUTHOR_TRACE_MARKER=str(self.path / 'write-trace'))
        if inprocess:
            stdout, stderr, code = io.StringIO(), io.StringIO(), 0
            with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    override.prepare(['gh', 'pr', 'merge', '123',
                                      *(args or ['--admin', '--match-head-commit', HEAD])], check_only=mode == 'check')
                except (ValueError, KeyError, TypeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                    code = 2
                    print('BLOCKED: owner admin authorization:', error, file=stderr)
            return subprocess.CompletedProcess([], code, stdout.getvalue(), stderr.getvalue())
        return subprocess.run([*command, 'gh', 'pr', 'merge', '123',
                               *(args or ['--admin', '--match-head-commit', HEAD])], env=env,
                              capture_output=True, text=True, timeout=60)

    def assert_inventory_refused(self, pages, message=None, *, mode='prepare'):
        self.state['inventory_pages'] = pages
        result = self.run_prepare(mode=mode)
        self.assertEqual(result.returncode, 2, result.stderr)
        if message:
            self.assertIn(message, result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())
        calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
        self.assertFalse(any('-f' in call and any(value.startswith('body=') for value in call) for call in calls))

    def test_exact_record_posts_quote_red_gates_before_writer(self):
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        posted = json.loads((self.path / 'posted.json').read_text())
        self.assertIn(AUTH['authorization_quote'], posted['body'])
        self.assertIn('Merge clearance gate', posted['body'])
        calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
        self.assertEqual(calls[-1][:3], ['pr', 'view', URL])
        self.assertEqual(calls[-1][-1], override.PR_FIELDS + ',labels')

    def test_complete_histories_at_and_above_cli_ceiling_publish_all_non_green_names(self):
        for count in (99, 100, 101, 203):
            with self.subTest(count=count):
                checks = [check_run(index, f'green-{index}') for index in range(count - 1)]
                checks.append(commit_status('red', 'off-page-status', 'PENDING'))
                self.state['inventory_pages'] = inventory_pages(self.state['pr'], checks)
                result = self.run_prepare()
                self.assertEqual(result.returncode, 0, result.stderr)
                posted = json.loads((self.path / 'posted.json').read_text())
                record = json.loads(posted['body'].split('```json\n')[1].split('\n```')[0])
                self.assertEqual(record['observed_red_gates'], ['off-page-status'])
                calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
                cursors = [value for call in calls if call[:2] == ['api', 'graphql']
                           for value in call if value.startswith('cursor=')]
                self.assertEqual(cursors, ['cursor=null', *[f'cursor=page-{index}' for index in range(1, len(self.state['inventory_pages']))]] * 3)
                (self.path / 'calls').unlink()
                (self.path / 'posted.json').unlink()

    def test_read_only_authorization_check_performs_no_github_write(self):
        checks = [check_run(index) for index in range(203)]
        self.state['inventory_pages'] = inventory_pages(self.state['pr'], checks)
        result = self.run_prepare(mode='check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())
        calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
        self.assertEqual(sum(call[:2] == ['api', 'graphql'] for call in calls), 6)

    def test_empty_inventory_is_distinguished_from_missing_rollup(self):
        empty = inventory_pages(self.state['pr'], [])
        null = copy.deepcopy(empty)
        null[0]['data']['repository']['object']['statusCheckRollup'] = None
        for pages in (empty, null):
            with self.subTest(pages=pages):
                self.state['inventory_pages'] = pages
                result = self.run_prepare()
                self.assertEqual(result.returncode, 0, result.stderr)
                (self.path / 'posted.json').unlink()
        missing = copy.deepcopy(empty)
        del missing[0]['data']['repository']['object']['statusCheckRollup']
        self.assert_inventory_refused(missing)

    def test_missing_failed_and_disappearing_later_pages_refuse_before_publication(self):
        pages = inventory_pages(self.state['pr'], [check_run(index) for index in range(101)])
        self.assert_inventory_refused(pages[:1])
        self.state['inventory_fail_page'] = 1
        self.assert_inventory_refused(pages)
        del self.state['inventory_fail_page']
        pages[1]['data']['repository']['object']['statusCheckRollup'] = None
        self.assert_inventory_refused(pages, 'disappeared')

    def test_malformed_graphql_envelopes_and_contexts_never_publish(self):
        baseline = self.state['inventory_pages']
        for page in (None, [], {}, {'errors': [{'message': 'partial read'}], **baseline[0]},
                     {'data': {'repository': None}}):
            with self.subTest(page=page):
                self.assert_inventory_refused([page])
        for node in (None, 'bad', {}, {'id': 'x', '__typename': 'OtherContext'},
                     {**check_run('x'), 'status': None}, {**check_run('x'), 'conclusion': 1},
                     {**check_run('x'), 'checkSuite': None}, {**commit_status('x'), 'creator': []}):
            with self.subTest(node=node):
                pages = copy.deepcopy(baseline)
                pages[0]['data']['repository']['object']['statusCheckRollup']['contexts']['nodes'] = [node]
                self.assert_inventory_refused(pages)

    def test_malformed_counts_pagination_and_wrong_commit_refuse(self):
        baseline = inventory_pages(self.state['pr'], [check_run(index) for index in range(101)])
        cases = [
            ('totalCount', True), ('totalCount', -1), ('totalCount', 102),
            ('checkRunCount', '101'), ('statusContextCount', 1),
            ('nodes', None), ('pageInfo', None), ('pageInfo', {}),
            ('pageInfo', {'hasNextPage': 'true', 'endCursor': 'page-1'}),
            ('pageInfo', {'hasNextPage': True, 'endCursor': None}),
            ('pageInfo', {'hasNextPage': True, 'endCursor': 7}),
            ('pageInfo', {'hasNextPage': False, 'endCursor': 'page-1'}),
        ]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                pages = copy.deepcopy(baseline)
                pages[0]['data']['repository']['object']['statusCheckRollup']['contexts'][key] = value
                self.assert_inventory_refused(pages)
        pages = copy.deepcopy(baseline)
        pages[0]['data']['repository']['object']['oid'] = 'c' * 40
        self.assert_inventory_refused(pages, 'different commit')
        for field in ('totalCount', 'nodes', 'pageInfo'):
            pages = copy.deepcopy(baseline)
            del pages[0]['data']['repository']['object']['statusCheckRollup']['contexts'][field]
            self.assert_inventory_refused(pages)

    def test_duplicate_contexts_count_drift_and_repeated_cursor_refuse(self):
        baseline = inventory_pages(self.state['pr'], [check_run(index) for index in range(203)])
        pages = copy.deepcopy(baseline)
        connection = pages[1]['data']['repository']['object']['statusCheckRollup']['contexts']
        connection['nodes'][0]['id'] = '0'
        self.assert_inventory_refused(pages, 'duplicate contexts')
        pages = copy.deepcopy(baseline)
        connection = pages[1]['data']['repository']['object']['statusCheckRollup']['contexts']
        connection['totalCount'] += 1
        connection['checkRunCount'] += 1
        self.assert_inventory_refused(pages, 'changed during pagination')
        pages = copy.deepcopy(baseline)
        pages[1]['data']['repository']['object']['statusCheckRollup']['contexts']['pageInfo']['endCursor'] = 'page-1'
        self.assert_inventory_refused(pages, 'cursor does not advance')

    def test_per_type_counts_must_match_the_observed_nodes(self):
        pages = inventory_pages(self.state['pr'], [commit_status('legacy', state='FAILURE')])
        connection = pages[0]['data']['repository']['object']['statusCheckRollup']['contexts']
        connection.update(checkRunCount=1, statusContextCount=0)
        self.assert_inventory_refused(pages, 'incomplete')

    def test_same_name_success_never_masks_a_later_non_green_producer(self):
        checks = [check_run('old-run', 'shared-check', producer='old-producer'),
                  commit_status('old-status', 'shared-status')]
        checks += [check_run(index, f'green-{index}') for index in range(98)]
        checks += [check_run('new-run', 'shared-check', 'FAILURE', producer='new-producer'),
                   commit_status('new-status', 'shared-status', 'PENDING'),
                   check_run('pending-run', 'pending-check', 'SUCCESS', status='IN_PROGRESS'),
                   check_run('skipped', conclusion='SKIPPED'), check_run('neutral', conclusion='NEUTRAL')]
        self.state['inventory_pages'] = inventory_pages(self.state['pr'], checks)
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        posted = json.loads((self.path / 'posted.json').read_text())
        record = json.loads(posted['body'].split('```json\n')[1].split('\n```')[0])
        self.assertEqual(record['observed_red_gates'], ['pending-check', 'shared-check', 'shared-status'])
        self.assertEqual(set(record), override.FIELDS | {'observed_codex_bot_login', 'observed_red_gates',
                                                       'observed_codex_inflight', 'observed_fresh_escalation'})

    def test_head_base_branch_and_state_changes_during_pagination_refuse(self):
        pages = inventory_pages(self.state['pr'], [check_run(index) for index in range(101)])
        for changes in ({'url': URL.replace('123', '124')}, {'headRefOid': 'c' * 40},
                        {'baseRefOid': 'c' * 40}, {'baseRefName': 'other'}, {'state': 'CLOSED'}):
            with self.subTest(changes=changes):
                self.state['page_pr_change'] = changes
                self.assert_inventory_refused(pages, 'open PR' if 'state' in changes else 'changed during check pagination')

    def test_prepublication_inventory_drift_refuses_even_with_the_same_red_gate_names(self):
        baseline = self.state['inventory_pages']
        for field, value in (('id', 'replacement'), ('status', 'IN_PROGRESS'),
                             ('startedAt', '2026-01-01T00:00:01Z'),
                             ('checkSuite', {'id': 'other-suite', 'app': {'id': 'other-producer'}})):
            with self.subTest(field=field):
                changed = copy.deepcopy(baseline)
                changed[0]['data']['repository']['object']['statusCheckRollup']['contexts']['nodes'][0][field] = value
                self.state['inventory_passes'] = [baseline, changed]
                for mode in ('prepare', 'check'):
                    self.assert_inventory_refused(baseline, 'changed before recording', mode=mode)

    def test_inventory_order_changes_do_not_change_the_observation(self):
        checks = [check_run('a'), commit_status('b', state='PENDING')]
        self.state['inventory_passes'] = [inventory_pages(self.state['pr'], checks),
                                          inventory_pages(self.state['pr'], list(reversed(checks)))]
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_final_read_failure_or_check_change_refuses_after_recording(self):
        for key in ('post_inventory_change', 'inventory_fail_after_post'):
            with self.subTest(key=key):
                self.state[key] = True
                result = self.run_prepare()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertTrue((self.path / 'posted.json').exists())
                self.state.pop(key)
                (self.path / 'posted.json').unlink()

    def test_final_pr_fences_apply_before_and_after_publication(self):
        for read in (2, 3):
            for field, value in (('url', URL.replace('123', '124')), ('headRefOid', 'c' * 40),
                                 ('baseRefOid', 'c' * 40), ('baseRefName', 'other'),
                                 ('state', 'CLOSED'), ('labels', [{'name': 'human-hold'}]), ('labels', None)):
                with self.subTest(read=read, field=field):
                    self.state['pr_read_changes'] = {str(read): {field: value}}
                    result = self.run_prepare()
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual((self.path / 'posted.json').exists(), read == 3)
                    (self.path / 'posted.json').unlink(missing_ok=True)

    def test_unanswered_request_arriving_before_publication_blocks_without_writing(self):
        self.state['prepost_codex'] = True
        result = self.run_prepare()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())
        result = self.run_prepare({**AUTH, 'allow_codex_inflight': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        posted = json.loads((self.path / 'posted.json').read_text())
        record = json.loads(posted['body'].split('```json\n')[1].split('\n```')[0])
        self.assertTrue(record['observed_codex_inflight'])

    def test_escalation_arriving_before_or_after_publication_keeps_its_explicit_exception(self):
        for key in ('prepost_escalation', 'late_escalation'):
            with self.subTest(key=key):
                self.state[key] = True
                result = self.run_prepare()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual((self.path / 'posted.json').exists(), key == 'late_escalation')
                (self.path / 'posted.json').unlink(missing_ok=True)
                result = self.run_prepare({**AUTH, 'allow_needs_human_review': True})
                self.assertEqual(result.returncode, 0, result.stderr)
                (self.path / 'posted.json').unlink()
                self.state.pop(key)

    def test_actual_author_wrapper_only_reaches_writer_after_complete_stable_inventory(self):
        # Canonical tests also run in consumers whose governing author can
        # differ. Exercise production files under a fixture-owned policy.
        wrapper_root = self.path / 'wrapper'
        for relative in ('scripts/gh-as-author.sh', 'scripts/identity-check.sh',
                         'scripts/workflow/owner-admin-override.py', 'scripts/lib/gh-token-resolver.sh',
                         'scripts/lib/gh-command-classifier.sh', 'scripts/lib/gh-rest-transport.sh',
                         'scripts/lib/credential-class.sh', 'scripts/lib/gh-comment-trigger-guard.sh',
                         'scripts/workflow/gh-comment-trigger-guard.py',
                         'scripts/lib/pr-body-contract.sh', 'scripts/lib/pr-body-contract.mjs',
                         'scripts/lib/reviewers-helpers.sh', 'scripts/lib/feedback-policy-helpers.sh'):
            target = wrapper_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        (wrapper_root / '.github').mkdir()
        (wrapper_root / '.github/review-policy.yml').write_text('author_identity: nathanjohnpayne\n')
        baseline = copy.deepcopy(self.state)
        cases = {
            'complete-large-history': {'inventory_pages': inventory_pages(self.state['pr'], [check_run(index) for index in range(203)])},
            'failed-page': {'inventory_pages': inventory_pages(self.state['pr'], [check_run(index) for index in range(101)]),
                            'inventory_fail_page': 1},
            'prepublication-drift': {'inventory_passes': [self.state['inventory_pages'], inventory_pages(self.state['pr'], [])]},
            'postpublication-drift': {'post_inventory_change': True},
            'bad-comment-author': {'bad_readback': True},
            'wrong-identity': {'identity': 'nathanpayne-codex'},
        }
        for name, changes in cases.items():
            with self.subTest(name=name):
                self.state = {**copy.deepcopy(baseline), **changes}
                for artifact in ('posted.json', 'merged.json', 'write-trace'):
                    (self.path / artifact).unlink(missing_ok=True)
                result = self.run_prepare(wrapper=True)
                success = name == 'complete-large-history'
                self.assertEqual(result.returncode, 0 if success else 2, result.stderr)
                self.assertEqual((self.path / 'merged.json').exists(), success)
                self.assertEqual((self.path / 'write-trace').exists(), success)
                self.assertEqual((self.path / 'posted.json').exists(),
                                 name in ('complete-large-history', 'postpublication-drift', 'bad-comment-author'))
                if success:
                    self.assertEqual(json.loads((self.path / 'merged.json').read_text()),
                                     ['pr', 'merge', '123', '--admin', '--match-head-commit', HEAD])

    def test_different_head_and_boolean_pin_refuse_without_post(self):
        for pin in ('1', URL + '@' + 'b' * 40):
            result = self.run_prepare(pin=pin)
            self.assertEqual(result.returncode, 2)
            self.assertFalse((self.path / 'posted.json').exists())

    def test_missing_match_future_timestamp_and_empty_quote_refuse(self):
        for record in ({**AUTH, 'authorized_at': '2999-01-01T00:00:00Z'}, {**AUTH, 'authorization_quote': ''}):
            self.assertEqual(self.run_prepare(record).returncode, 2)
        self.assertEqual(self.run_prepare(args=['--admin']).returncode, 2)

    def test_fresh_escalation_requires_named_authorization(self):
        self.state['timeline'] = [{'event': 'labeled', 'label': {'name': 'needs-human-review'}, 'created_at': '2026-01-01T00:00:01Z'}]
        self.assertEqual(self.run_prepare().returncode, 2)
        self.assertEqual(self.run_prepare({**AUTH, 'allow_needs_human_review': True}).returncode, 0)

    def test_completed_review_uses_governing_custom_bot(self):
        self.state['policy'] = {'codex': {'bot_login': 'custom-codex[bot]'}}
        self.state['comments'] = [{'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review', 'created_at': '2026-01-01T00:00:01Z'}]
        self.state['reviews'] = [{'user': {'login': 'custom-codex[bot]'}, 'commit_id': HEAD, 'body': 'review complete', 'submitted_at': '2026-01-01T00:00:02Z'}]
        self.assertEqual(self.run_prepare().returncode, 0)
        self.state['reviews'][0]['user']['login'] = override.BOT
        self.assertEqual(self.run_prepare().returncode, 2)

    def test_canonical_historical_completion_stays_terminal_in_prepare_and_check(self):
        requests, reviews, ledger = completion_fixture()
        self.assertEqual(ledger['requests'][0]['outcome'], 'attributed')
        self.state.update(comments=requests, reviews=reviews)
        with mock.patch.object(override, 'historical_request_ledger', return_value=ledger) as reader:
            for mode in ('check', 'prepare'):
                result = self.run_prepare(mode=mode, inprocess=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(reader.call_count, 4)
        posted = json.loads((self.path / 'posted.json').read_text())
        self.assertFalse(json.loads(posted['body'].split('```json\n')[1].split('\n```')[0])['observed_codex_inflight'])

    def test_historical_completion_rejects_changed_generation_before_publication(self):
        requests, reviews, ledger = completion_fixture()
        self.state.update(comments=requests, reviews=reviews, prepost_codex=True)
        with mock.patch.object(override, 'historical_request_ledger', return_value=ledger):
            result = self.run_prepare(inprocess=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())

    def test_historical_completion_rejects_changed_generation_after_publication(self):
        requests, reviews, ledger = completion_fixture()
        self.state.update(comments=requests, reviews=reviews, late_codex=True)
        with mock.patch.object(override, 'historical_request_ledger', return_value=ledger):
            result = self.run_prepare(inprocess=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue((self.path / 'posted.json').exists())

    def test_canonical_historical_completion_retains_active_and_ambiguous_holds(self):
        requests, reviews, ledger = completion_fixture()
        def inflight(comments=requests, runs=reviews, evidence=ledger):
            return override.codex_inflight(comments, runs, [], HEAD, 'nathanjohnpayne',
                                            ledger=evidence, repository='example/repo')
        self.assertTrue(inflight(evidence=None))
        self.assertFalse(inflight())
        for anchor in (HEAD, 'b' * 40):
            for status in ('Running', 'Unknown'):
                summary = {'id': 902, 'user': {'login': override.BOT}, 'created_at': '2026-01-01T00:00:03Z',
                           'body': '<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | **' + status + '** | `' + anchor + '` | Manual |'}
                self.assertTrue(inflight(comments=requests + [summary]))
        self.assertTrue(inflight(comments=[{**requests[0], 'updated_at': '2026-01-01T00:00:02Z'}]))
        new_request = {**requests[0], 'id': 802, 'created_at': '2026-01-01T00:00:03Z'}
        self.assertTrue(inflight(comments=requests + [new_request]))
        ambiguous_requests, ambiguous_reviews, ambiguous = completion_fixture(
            requests=[requests[0], {**new_request, 'created_at': '2026-01-01T00:00:02Z'}],
            response_time='2026-01-01T00:00:03Z')
        self.assertTrue(inflight(ambiguous_requests, ambiguous_reviews, ambiguous))
        _, reply_reviews, reply_ledger = completion_fixture(replies=True)
        inline = [{'pull_request_review_id': 901, 'in_reply_to_id': 900, 'user': {'login': override.BOT}}]
        self.assertTrue(override.codex_inflight(requests, reply_reviews, inline, HEAD, 'nathanjohnpayne', ledger=reply_ledger))
        for key, value in [('head_sha', 'c' * 40), ('author', 'other'), ('bot', 'other'), ('repo', 'other/repo'), ('requests', [])]:
            self.assertTrue(inflight(evidence={**ledger, key: value}), key)
        for evidence in (None, {}, {'requests': 'unreadable'}):
            self.assertTrue(inflight(evidence=evidence))
        for field, value in [('anchor', 'b' * 7), ('tie', True), ('mixed_heads', True), ('anchor_conflict', True)]:
            malformed = copy.deepcopy(ledger)
            malformed['responses'][0][field] = value
            self.assertTrue(inflight(evidence=malformed), field)
        _, tied_reviews, tied_ledger = completion_fixture(response_time=requests[0]['created_at'])
        self.assertTrue(inflight(requests, tied_reviews, tied_ledger))

    def test_historical_completion_reader_failure_and_wrong_target_stay_blocking(self):
        requests, reviews, ledger = completion_fixture()
        for value in (None, [], {}, {**ledger, 'pr': 124}):
            with mock.patch.object(override, 'historical_request_ledger', return_value=value):
                self.assertTrue(override.observe_codex_inflight(requests, reviews, [], HEAD,
                                                               'nathanjohnpayne', 'example/repo', 123))
        for error in (OSError('unavailable'), ValueError('unreadable'), subprocess.TimeoutExpired('ledger', 300)):
            with mock.patch.object(override, 'historical_request_ledger', side_effect=error):
                self.assertTrue(override.observe_codex_inflight(requests, reviews, [], HEAD,
                                                               'nathanjohnpayne', 'example/repo', 123))

    def test_historical_completion_audit_keeps_merge_time_and_generation_fences(self):
        requests, reviews, ledger = completion_fixture()
        self.state.update(comments=requests, reviews=reviews)
        with mock.patch.object(override, 'historical_request_ledger', return_value=ledger):
            self.assertEqual(self.run_prepare(inprocess=True).returncode, 0)
            posted = json.loads((self.path / 'posted.json').read_text())
            payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                       'author': 'nathanjohnpayne', 'comments': requests + [posted], 'reviews': reviews, 'inline_comments': []}
            self.assertTrue(override.audit(payload)['recorded_override'])
            payload['comments'].append({**requests[0], 'id': 802, 'created_at': '2026-01-01T00:01:01Z'})
            self.assertFalse(override.audit(payload)['recorded_override'])
        _, late_reviews, late_ledger = completion_fixture(response_time='2026-01-01T00:03:00Z')
        payload.update(comments=requests + [posted], reviews=late_reviews)
        with mock.patch.object(override, 'historical_request_ledger', return_value=late_ledger):
            self.assertFalse(override.audit(payload)['recorded_override'])

    def test_historical_audit_ignores_a_valid_post_merge_request(self):
        requests, reviews, ledger = completion_fixture()
        self.state.update(comments=requests, reviews=reviews)
        with mock.patch.object(override, 'historical_request_ledger', return_value=ledger):
            self.assertEqual(self.run_prepare(inprocess=True).returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        later = {**requests[0], 'id': 802, 'created_at': '2026-01-01T00:03:00Z'}
        all_requests, _, live_ledger = completion_fixture(requests=requests + [later])
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'comments': all_requests + [posted],
                   'reviews': reviews, 'inline_comments': []}
        with mock.patch.object(override, 'historical_request_ledger', return_value=live_ledger):
            self.assertTrue(override.audit(payload)['recorded_override'])
        self.assertTrue(override.codex_inflight(all_requests, reviews, [], HEAD, 'nathanjohnpayne',
                                               ledger=live_ledger, repository='example/repo'))

    def test_historical_request_cutoff_keeps_boundary_and_unanswered_requests(self):
        requests, _, ledger = completion_fixture()
        cutoff = '2026-01-01T00:02:00Z'
        for created in ('2026-01-01T00:01:00Z', cutoff):
            later = {**requests[0], 'id': 802, 'created_at': created}
            observed, _, evidence = completion_fixture(requests=requests + [later])
            self.assertFalse(override.historical_requests_completed(
                evidence, observed, HEAD, 'nathanjohnpayne', override.BOT, cutoff, 'example/repo'))
        # An uncounted pre-cutoff retry still needs its attributed response.
        evidence = copy.deepcopy(ledger)
        evidence['requests'].append({**evidence['requests'][0], 'id': 802, 'counted': False,
                                     'outcome': 'pending', 'responses': []})
        self.assertFalse(override.historical_requests_completed(
            evidence, requests, HEAD, 'nathanjohnpayne', override.BOT, cutoff, 'example/repo'))

    def test_historical_cutoff_validates_request_timestamps_before_filtering(self):
        requests, _, ledger = completion_fixture()
        cutoff = '2026-01-01T00:02:00Z'
        for value in (None, 7, '', '2026-99-01T00:03:00Z', '2026-01-01T00:03:00+00:00'):
            with self.subTest(request_timestamp=value):
                evidence = copy.deepcopy(ledger)
                evidence['requests'].append({**evidence['requests'][0], 'id': 802, 'created_at': value,
                                             'outcome': 'pending', 'responses': []})
                self.assertFalse(override.historical_requests_completed(
                    evidence, requests, HEAD, 'nathanjohnpayne', override.BOT, cutoff, 'example/repo'))
        for value in (7, '', '2026-02-30T00:02:00Z'):
            with self.subTest(cutoff=value):
                self.assertFalse(override.historical_requests_completed(
                    ledger, requests, HEAD, 'nathanjohnpayne', override.BOT, value, 'example/repo'))

    def test_historical_cutoff_ignores_only_well_formed_future_request_rows(self):
        requests, _, ledger = completion_fixture()
        later = {**requests[0], 'id': 802, 'created_at': '2026-01-01T00:03:00Z'}
        all_requests, _, evidence = completion_fixture(requests=requests + [later])
        cutoff = '2026-01-01T00:02:00Z'
        self.assertTrue(override.historical_requests_completed(
            evidence, all_requests, HEAD, 'nathanjohnpayne', override.BOT, cutoff, 'example/repo'))
        self.assertFalse(override.historical_requests_completed(
            evidence, all_requests, HEAD, 'nathanjohnpayne', override.BOT, repository='example/repo'))
        for field, value in (('counted', 1), ('id', True), ('id', -1), ('created_at', [])):
            with self.subTest(field=field, value=value):
                malformed = copy.deepcopy(evidence)
                malformed['requests'][-1][field] = value
                self.assertFalse(override.historical_requests_completed(
                    malformed, requests, HEAD, 'nathanjohnpayne', override.BOT, cutoff, 'example/repo'))
        for field, value in (('id', True), ('id', -1), ('created_at', [])):
            with self.subTest(comment_field=field, value=value):
                malformed = copy.deepcopy(all_requests)
                malformed[-1][field] = value
                self.assertFalse(override.historical_requests_completed(
                    evidence, malformed, HEAD, 'nathanjohnpayne', override.BOT, cutoff, 'example/repo'))

    def test_malformed_governing_bot_fails_before_recording(self):
        self.state['policy'] = {'codex': {'bot_login': ['custom-codex[bot]']}}
        result = self.run_prepare()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())

    def test_unfinished_codex_requires_named_authorization(self):
        for command in ('@codex review', '@Codex review', '@CODEX REVIEW'):
            self.state['comments'] = [{'user': {'login': 'nathanjohnpayne'}, 'body': command, 'created_at': '2026-01-01T00:00:01Z'}]
            self.assertEqual(self.run_prepare().returncode, 2)
        self.assertEqual(self.run_prepare({**AUTH, 'allow_codex_inflight': True}).returncode, 0)

    def test_whitespace_padded_commands_do_not_start_requests(self):
        for command in (' @codex review', '@codex review ', '@codex review\n'):
            with self.subTest(command=command):
                self.state['comments'] = [{'user': {'login': 'nathanjohnpayne'}, 'body': command,
                                           'created_at': '2026-01-01T00:00:01Z'}]
                result = self.run_prepare()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_audit_retains_recorded_governing_bot_after_policy_changes(self):
        self.state['policy'] = {'codex': {'bot_login': 'historical-codex[bot]'}}
        request = {'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review',
                   'created_at': '2026-01-01T00:00:01Z'}
        response = {'user': {'login': 'historical-codex[bot]'}, 'commit_id': HEAD,
                    'body': 'review complete', 'submitted_at': '2026-01-01T00:00:02Z'}
        self.state.update(comments=[request], reviews=[response])
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'codex_bot_login': 'replacement-codex[bot]',
                   'comments': [request, posted], 'reviews': [response], 'inline_comments': []}
        self.assertTrue(override.audit(payload)['recorded_override'])
        response['user']['login'] = 'replacement-codex[bot]'
        self.assertFalse(override.audit(payload)['recorded_override'])

    def test_existing_record_must_postdate_authorization(self):
        record = {**AUTH, 'authorized_at': '2026-01-01T00:00:30Z'}
        self.assertEqual(self.run_prepare(record).returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        for created, expected_posts in [('2026-01-01T00:00:10Z', 1), ('2026-01-01T00:01:00Z', 0)]:
            self.state['comments'] = [{**posted, 'created_at': created}]
            (self.path / 'calls').write_text('')
            result = self.run_prepare(record)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
            writes = [call for call in calls if call[0] == 'api' and call[1].endswith('/comments') and '-f' in call]
            self.assertEqual(len(writes), expected_posts)

    def test_anchored_issue_comment_is_a_response_observation(self):
        self.state['comments'] = [
            {'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review', 'created_at': '2026-01-01T00:00:01Z'},
            {'user': {'login': override.BOT}, 'body': '**Reviewed commit:** `' + HEAD[:10] + '`',
             'created_at': '2026-01-01T00:00:02Z'}]
        self.assertEqual(self.run_prepare().returncode, 0)
        for body in ('Reviewed commit: ' + 'b'*10, 'Reviewed commit: ' + HEAD[:10] + '.trailing',
                     'Reviewed commit: ' + HEAD[:10] + '\nReviewed commit: ' + HEAD):
            self.state['comments'][1]['body'] = body
            self.assertEqual(self.run_prepare().returncode, 2)

    def test_running_summary_without_an_explicit_request_blocks(self):
        self.state['comments'] = [{'user': {'login': override.BOT}, 'created_at': '2026-01-01T00:00:01Z',
                                  'body': '<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | **Running** | `' + HEAD[:8] + '` | Automatic |'}]
        self.assertEqual(self.run_prepare().returncode, 2)

    def test_completed_summary_finishes_request_without_granting_clearance(self):
        self.state['comments'] = [
            {'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review', 'created_at': '2026-01-01T00:00:01Z'},
            {'id': 2, 'user': {'login': override.BOT}, 'created_at': '2026-01-01T00:00:00Z',
             'updated_at': '2026-01-01T00:00:02Z', 'body': '<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | **Completed** | `' + HEAD[:8] + '` | Manual request |'}]
        self.assertEqual(self.run_prepare().returncode, 0)
        for replacement in (HEAD[:8].replace('a', 'b'), HEAD[:8] + '.trailing'):
            self.state['comments'][1]['body'] = self.state['comments'][1]['body'].replace(HEAD[:8], replacement)
            self.assertEqual(self.run_prepare().returncode, 2)
            self.state['comments'][1]['body'] = self.state['comments'][1]['body'].replace(replacement, HEAD[:8])
        self.state['comments'][0]['created_at'] = '2026-01-01T00:00:03Z'
        self.assertEqual(self.run_prepare().returncode, 2)

    def test_weekly_audit_reports_record_without_other_violations(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        workflow = (ROOT / '.github/workflows/pr-audit.yml').read_text()
        # The per-PR audit closing brace bounds collection independently of any
        # declarations or conditions added to the later report renderer.
        collection = workflow.split('              let recordedOverride = null;', 1)[1].split('\n            }\n', 1)[0]
        # The extracted collection uses the real API/deadline wrappers too.
        # Exercise those dependencies rather than an unbound fragment or stubs.
        budget = workflow.split('            const PR_BODY_PARSE_TIMEOUT_MS', 1)[1].split('\n            function parsePrBodyContract', 1)[0]
        budget = 'const PR_BODY_PARSE_TIMEOUT_MS' + budget
        rendering = workflow.split('              if (recordedOverrides.length > 0) {', 1)[1].split('              body += `\\n---', 1)[0]
        pr = {'number': 123, 'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'}
        setup = '''const context={repo:{owner:'example',repo:'repo'}};
const prViolations=[],recordedOverrides=[],violations=[];
let auditedPRCount=0;
const hadHumanHold=false,hadPolicyViolation=false,hadHumanLabel=false;
const authorIdentity='nathanjohnpayne',codexBotLogin='chatgpt-codex-connector[bot]';
const core={warning:message=>{throw new Error(message)}};
const github={rest:{issues:{listComments:'comments'},pulls:{listReviews:'reviews',listReviewComments:'inline'}},paginate:async endpoint=>endpoint==='comments'?[posted]:[]};
'''
        code = 'const pr=' + json.dumps(pr) + ',posted=' + json.dumps(posted) + ';\n' + setup + budget
        code += '(async()=>{let recordedOverride=null;' + collection
        code += '\nlet body="";if(recordedOverrides.length>0){' + rendering
        code += '\nconsole.log(JSON.stringify({recordedOverrides,violations,body,auditedPRCount}));})().catch(e=>{console.error(e);process.exit(1)});'
        result = subprocess.run(['node', '-e', code], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report['recordedOverrides']), 1)
        self.assertEqual(report['violations'], [])
        self.assertEqual(report['auditedPRCount'], 1)
        self.assertIn('Merge clearance gate', report['body'])
        self.assertIn('authorization record', report['body'])

    def test_reply_wrapper_cannot_complete_an_unanswered_request(self):
        self.state['comments'] = [{'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review', 'created_at': '2026-01-01T00:00:01Z'}]
        self.state['reviews'] = [{'id':901,'user': {'login': override.BOT}, 'commit_id':HEAD, 'body':'', 'submitted_at':'2026-01-01T00:00:02Z'}]
        self.state['inline'] = [{'pull_request_review_id':901, 'in_reply_to_id':900, 'user': {'login': override.BOT}}]
        self.assertEqual(self.run_prepare().returncode, 2)

    def test_hard_holds_stay_blocked(self):
        for label in ('human-hold', 'policy-violation'):
            self.state['pr']['labels'] = [{'name': label}]
            self.assertEqual(self.run_prepare({**AUTH, 'allow_needs_human_review': True, 'allow_codex_inflight': True}).returncode, 2)

    def test_head_move_and_wrong_comment_author_refuse_writer(self):
        for case in ('move', 'bad_readback'):
            self.state[case] = True
            self.assertEqual(self.run_prepare().returncode, 2)
            self.state[case] = False

    def test_labels_added_before_final_read_refuse_writer(self):
        for label in ('human-hold', 'policy-violation', 'needs-human-review'):
            self.state['late_label'] = label
            result = self.run_prepare()
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertTrue((self.path / 'posted.json').exists())

    def test_request_after_initial_observation_requires_exception(self):
        self.state['late_codex'] = True
        self.assertEqual(self.run_prepare().returncode, 2)
        self.assertEqual(self.run_prepare({**AUTH, 'allow_codex_inflight': True}).returncode, 0)

    def test_gh_timeout_is_bounded_and_exits_blocked(self):
        with mock.patch.dict(os.environ, {'GH_AS_AUTHOR_RECORD_IDENTITY': 'nathanjohnpayne'}), \
                mock.patch('sys.argv', [str(SCRIPT), 'prepare', 'gh', 'pr', 'merge', '123', '--admin']), \
                mock.patch('shutil.which', return_value='/fixture/gh'), \
                mock.patch('subprocess.run', side_effect=subprocess.TimeoutExpired('gh', 300)) as call, \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            with self.assertRaises(SystemExit) as exit_result:
                runpy.run_path(str(SCRIPT), run_name='__main__')
        self.assertEqual(exit_result.exception.code, 2)
        self.assertEqual(call.call_args.kwargs['timeout'], 300)
        self.assertIn('BLOCKED: owner admin authorization:', stderr.getvalue())

    def test_audit_requires_explicit_human_label_exception(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'comments': [posted], 'reviews': [], 'inline_comments': [], 'needs_human_review_at_merge': True}
        self.assertFalse(override.audit(payload)['recorded_override'])
        self.assertEqual(self.run_prepare({**AUTH, 'allow_needs_human_review': True}).returncode, 0)
        payload['comments'] = [json.loads((self.path / 'posted.json').read_text())]
        self.assertTrue(override.audit(payload)['recorded_override'])
        payload['hard_hold_at_merge'] = True
        self.assertFalse(override.audit(payload)['recorded_override'])

    def test_quoted_admin_subject_is_an_ordinary_merge(self):
        self.assertIsNone(override.merge_args(['gh', 'pr', 'merge', '123', '--subject', '--admin']))
        self.assertIsNone(override.merge_args(['gh', 'pr', 'merge', '123', '--admin=false']))
        self.assertIsNone(override.merge_args(['gh', 'pr', 'create', '--title', '--admin']))

    def test_aliases_and_extensions_cannot_hide_an_admin_merge(self):
        for command in (['pm', '123', '--admin'], ['pm', '123'], ['image', '--admin'],
                        ['extension', 'exec', 'pm', '123', '--admin']):
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, 'literal built-in'):
                override.prepare(['gh', *command])
        self.assertFalse((self.path / 'calls').exists())
        for command in ('api', 'issue', 'run', 'repo', 'alias', 'discussion'):
            self.assertIsNone(override.merge_args(['gh', command, '--help']))

    def test_raw_merge_api_writes_cannot_bypass_scoped_preparation(self):
        requests = [
            ['repos/example/repo/pulls/123/merge', '-X', 'PUT'],
            ['repos/example/repo/pulls/123/merge', '-iXPUT'],
            ['repos/example/repo/pulls/123/merge', '-iX', 'PUT'],
            ['-XPUT', 'repos/example/repo/pulls/123/merge'],
            ['https://api.github.com/repos/example/repo/pulls/123/merge', '--method=PUT'],
            ['repos/example/repo/%70ulls/123/merge', '-f', 'merge_method=squash'],
            ['repos/{owner}/{repo}/pulls/{number}/merge', '--input', '-'],
            ['graphql', '-f', 'query=mutation { mergePullRequest(input:{pullRequestId:"PR_x"}) {clientMutationId}}'],
            ['graphql', '--raw-field=query=mutation { m:mergePullRequest(input:{}) {clientMutationId}}'],
            ['graphql', '-Fquery=@payload.graphql'],
            ['graphql', '-F', 'query=@-'],
            ['graphql', '--input', 'payload.json'],
            ['graphql', '--input=-'],
            ['graphql', '-f', 'query=query { viewer {login}}', '-f', 'query=mutation {mergePullRequest(input:{}){clientMutationId}}'],
            # Arming auto-merge or entering the queue merges without the gates too.
            ['graphql', '-f', 'query=mutation { enablePullRequestAutoMerge(input:{pullRequestId:"PR_x"}) {clientMutationId}}'],
            ['graphql', '-f', 'query=mutation { disablePullRequestAutoMerge(input:{pullRequestId:"PR_x"}) {clientMutationId}}'],
            ['graphql', '-f', 'query=mutation { addPullRequestToMergeQueue(input:{pullRequestId:"PR_x"}) {clientMutationId}}'],
            ['graphql', '-f', 'query=mutation { enqueuePullRequest(input:{pullRequestId:"PR_x"}) {clientMutationId}}'],
            ['graphql', '-f', 'query=mutation { dequeuePullRequest(input:{id:"MQE_x"}) {clientMutationId}}'],
        ]
        for request in requests:
            with self.subTest(request=request), self.assertRaisesRegex(ValueError, 'merge|literal query'):
                override.prepare(['gh', 'api', *request])
        self.assertFalse((self.path / 'calls').exists())

    def test_non_merge_api_reads_and_inspectable_mutations_are_unchanged(self):
        requests = [
            ['repos/example/repo/pulls/123/merge'],
            ['repos/example/repo/issues/123/comments', '-f', 'body=hello'],
            ['graphql', '-f', 'query=query {viewer {login}}'],
            ['graphql', '-f', 'query=mutation {addComment(input:{subjectId:"I_x",body:"hello"}) {clientMutationId}}'],
            ['graphql', '--help'],
            ['repos/example/repo/issues', '--preview', 'some-preview'],
            ['--preview', 'some-preview', 'repos/example/repo/issues'],
            ['repos/example/repo/issues', '-p', 'some-preview'],
            ['repos/example/repo/issues', '-psome-preview'],
        ]
        for request in requests:
            with self.subTest(request=request):
                override.prepare(['gh', 'api', *request])
        self.assertFalse((self.path / 'calls').exists())

    def test_inherited_repository_options_before_merge_are_recognized(self):
        for flags in (['--repo', 'example/repo'], ['--repo=example/repo'], ['-R', 'example/repo'], ['-Rexample/repo']):
            self.assertEqual(override.merge_args(['gh', 'pr', *flags, 'merge', '123', '--admin']),
                             ('123', 'example/repo', []))

    def test_audit_requires_author_head_and_timestamp_order(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'comments': [posted], 'reviews': [], 'inline_comments': []}
        self.assertTrue(override.audit(payload)['recorded_override'])
        for mutation in ('author', 'head', 'time', 'postmerge-edit', 'missing-edit-time'):
            bad = copy.deepcopy(payload)
            if mutation == 'author': bad['comments'][0]['user']['login'] = 'github-actions[bot]'
            elif mutation == 'head': bad['pr']['head']['sha'] = 'b' * 40
            elif mutation == 'time': bad['comments'][0]['created_at'] = '2026-01-01T00:03:00Z'
            elif mutation == 'postmerge-edit': bad['comments'][0]['updated_at'] = '2026-01-01T00:03:00Z'
            else: del bad['comments'][0]['updated_at']
            self.assertFalse(override.audit(bad)['recorded_override'])

    def test_audit_does_not_accept_malformed_observed_state(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        record = json.loads(posted['body'].split('```json\n', 1)[1].rsplit('\n```', 1)[0])
        for key, value in (('version', True), ('observed_codex_bot_login', ''),
                           ('observed_codex_bot_login', 9), ('observed_codex_inflight', 'false'),
                           ('observed_fresh_escalation', 0), ('observed_red_gates', 'lint')):
            bad = copy.deepcopy(record)
            bad[key] = value
            altered = dict(posted, body=override.MARKER + '\n```json\n' + json.dumps(bad) + '\n```')
            payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                       'author': 'nathanjohnpayne', 'comments': [altered], 'reviews': [], 'inline_comments': []}
            self.assertFalse(override.audit(payload)['recorded_override'])

    def test_audit_observes_unanswered_request_at_merge(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        request = {'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review', 'created_at': '2026-01-01T00:01:01Z'}
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'comments': [posted, request], 'reviews': [], 'inline_comments': []}
        self.assertFalse(override.audit(payload)['recorded_override'])
        response = {'user': {'login': override.BOT}, 'body': 'Reviewed commit: ' + HEAD,
                    'created_at': '2026-01-01T00:03:00Z'}
        payload['comments'].append(response)
        self.assertFalse(override.audit(payload)['recorded_override'])
        response['created_at'] = '2026-01-01T00:01:59Z'
        self.assertTrue(override.audit(payload)['recorded_override'])
        payload['codex_bot_login'] = 'custom-codex[bot]'
        self.assertTrue(override.audit(payload)['recorded_override'])
        response['user']['login'] = 'custom-codex[bot]'
        self.assertFalse(override.audit(payload)['recorded_override'])
        response['user']['login'] = override.BOT
        request['updated_at'] = '2026-01-01T00:03:00Z'
        self.assertFalse(override.audit(payload)['recorded_override'])
        request['body'] = 'edited away'
        self.assertFalse(override.audit(payload)['recorded_override'])

    def test_audit_retains_edited_bot_summary_uncertainty(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        summary = {'user': {'login': override.BOT}, 'created_at': '2026-01-01T00:01:30Z',
                   'updated_at': '2026-01-01T00:03:00Z',
                   'body': '<!-- codex-pull-request-review-summary -->\n| Code Review | Completed | `' + HEAD[:8] + '` | Automatic |'}
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'comments': [posted, summary], 'reviews': [], 'inline_comments': []}
        self.assertFalse(override.audit(payload)['recorded_override'])
        summary['body'] = 'edited away'
        self.assertFalse(override.audit(payload)['recorded_override'])
        summary['user']['login'] = 'custom-codex[bot]'
        payload['codex_bot_login'] = 'custom-codex[bot]'
        self.assertTrue(override.audit(payload)['recorded_override'])


if __name__ == '__main__':
    unittest.main()
