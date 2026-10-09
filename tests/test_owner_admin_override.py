#!/usr/bin/env python3
"""Exercise the actual admin writer preparation and audit record parser."""
import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

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


class OverrideTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.state = {'pr': {'url': URL, 'headRefOid': HEAD, 'labels': [],
                            'statusCheckRollup': [{'name': 'Merge clearance gate', 'conclusion': 'FAILURE'}]},
                      'comments': [], 'reviews': [], 'timeline': []}
        stub = self.path / 'gh'
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['OVERRIDE_CASE']); s=json.loads((p/'state.json').read_text()); a=sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['pr','view']:
 result=s['pr'].copy()
 if (p/'posted.json').exists() and s.get('move'): result['headRefOid']='b'*40
elif a[:3]==['api','--paginate','--slurp']:
 suffix=a[3].split('/')[-1]; result=[s.get('inline' if '/pulls/' in a[3] and suffix=='comments' else suffix,[])]
elif a[0]=='api' and '/issues/comments/' in a[1]:
 result=json.loads((p/'posted.json').read_text())
elif a[0]=='api' and a[1].endswith('/comments') and '-f' in a:
 body=a[a.index('-f')+1][5:]; result={'id':77,'body':body,'user':{'login':'nathanjohnpayne'},'created_at':'2026-01-01T00:01:00Z','html_url':'https://github.com/example/repo/pull/123#issuecomment-77'}
 if s.get('bad_readback'): result['user']['login']='wrong-account'
 (p/'posted.json').write_text(json.dumps(result))
else: sys.exit(9)
print(json.dumps(result))
''')
        stub.chmod(0o755)

    def run_prepare(self, record=None, args=None, pin=None):
        (self.path / 'state.json').write_text(json.dumps(self.state))
        env = {**os.environ, 'PATH': str(self.path) + os.pathsep + os.environ['PATH'],
               'OVERRIDE_CASE': str(self.path), 'GH_AS_AUTHOR_RECORD_IDENTITY': 'nathanjohnpayne',
               'BREAK_GLASS_ADMIN': pin or URL + '@' + HEAD,
               'MERGEPATH_OWNER_ADMIN_AUTHORIZATION': json.dumps(record or AUTH)}
        return subprocess.run(['python3', str(SCRIPT), 'prepare', 'gh', 'pr', 'merge', '123',
                               *(args or ['--admin', '--match-head-commit', HEAD])], env=env,
                              capture_output=True, text=True)

    def test_exact_record_posts_quote_red_gates_before_writer(self):
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        posted = json.loads((self.path / 'posted.json').read_text())
        self.assertIn(AUTH['authorization_quote'], posted['body'])
        self.assertIn('Merge clearance gate', posted['body'])
        calls = [json.loads(line) for line in (self.path / 'calls').read_text().splitlines()]
        self.assertEqual(calls[-1][:2], ['pr', 'view'])

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

    def test_unfinished_codex_requires_named_authorization(self):
        self.state['comments'] = [{'user': {'login': 'nathanjohnpayne'}, 'body': '@codex review', 'created_at': '2026-01-01T00:00:01Z'}]
        self.assertEqual(self.run_prepare().returncode, 2)
        self.assertEqual(self.run_prepare({**AUTH, 'allow_codex_inflight': True}).returncode, 0)

    def test_running_summary_without_an_explicit_request_blocks(self):
        self.state['comments'] = [{'user': {'login': override.BOT}, 'created_at': '2026-01-01T00:00:01Z',
                                  'body': '<!-- codex-pull-request-review-summary -->\n| Code Review | Running | `' + HEAD[:8] + '` | Automatic |'}]
        self.assertEqual(self.run_prepare().returncode, 2)

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

    def test_quoted_admin_subject_is_an_ordinary_merge(self):
        self.assertIsNone(override.merge_args(['gh', 'pr', 'merge', '123', '--subject', '--admin']))
        self.assertIsNone(override.merge_args(['gh', 'pr', 'merge', '123', '--admin=false']))
        self.assertIsNone(override.merge_args(['gh', 'pr', 'create', '--title', '--admin']))

    def test_audit_requires_author_head_and_timestamp_order(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                   'author': 'nathanjohnpayne', 'comments': [posted]}
        self.assertTrue(override.audit(payload)['recorded_override'])
        for mutation in ('author', 'head', 'time'):
            bad = copy.deepcopy(payload)
            if mutation == 'author': bad['comments'][0]['user']['login'] = 'github-actions[bot]'
            elif mutation == 'head': bad['pr']['head']['sha'] = 'b' * 40
            else: bad['comments'][0]['created_at'] = '2026-01-01T00:03:00Z'
            self.assertFalse(override.audit(bad)['recorded_override'])

    def test_audit_does_not_accept_malformed_observed_state(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        posted = json.loads((self.path / 'posted.json').read_text())
        record = json.loads(posted['body'].split('```json\n', 1)[1].rsplit('\n```', 1)[0])
        for key, value in (('version', True), ('observed_codex_inflight', 'false'),
                           ('observed_fresh_escalation', 0), ('observed_red_gates', 'lint')):
            bad = copy.deepcopy(record)
            bad[key] = value
            altered = dict(posted, body=override.MARKER + '\n```json\n' + json.dumps(bad) + '\n```')
            payload = {'pr': {'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'},
                       'author': 'nathanjohnpayne', 'comments': [altered]}
            self.assertFalse(override.audit(payload)['recorded_override'])


if __name__ == '__main__':
    unittest.main()
