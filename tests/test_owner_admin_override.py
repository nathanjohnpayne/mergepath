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


class OverrideTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.state = {'pr': {'url': URL, 'headRefOid': HEAD, 'baseRefOid': 'b' * 40, 'labels': [],
                            'statusCheckRollup': [{'name': 'Merge clearance gate', 'conclusion': 'FAILURE'}]},
                      'comments': [], 'reviews': [], 'timeline': []}
        stub = self.path / 'gh'
        stub.write_text('''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
p=Path(os.environ['OVERRIDE_CASE']); s=json.loads((p/'state.json').read_text()); a=sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['pr','view']:
 result=s['pr'].copy()
 if (p/'posted.json').exists() and s.get('move'): result['headRefOid']='b'*40
 if (p/'posted.json').exists() and s.get('late_label'): result['labels']=[{'name':s['late_label']}]
elif a[0]=='api' and '/contents/.github/review-policy.yml?ref=' in a[1]:
 result={'encoding':'base64','content':base64.b64encode(json.dumps(s.get('policy',{})).encode()).decode()}
elif a[:3]==['api','--paginate','--slurp']:
 suffix=a[3].split('/')[-1]; result=[s.get('inline' if '/pulls/' in a[3] and suffix=='comments' else suffix,[])]
 if (p/'posted.json').exists() and s.get('late_codex') and '/issues/' in a[3] and suffix=='comments':
  result=[[*result[0],{'user':{'login':'nathanjohnpayne'},'body':'@codex review','created_at':'2026-01-01T00:01:01Z'}]]
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
        self.assertEqual(calls[-1][:3], ['api', '--paginate', '--slurp'])

    def test_rollup_at_cli_ceiling_refuses_before_recording(self):
        self.state['pr']['statusCheckRollup'] = [{'name': 'green', 'conclusion': 'SUCCESS'}] * 100
        result = self.run_prepare()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('may be truncated', result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())
        self.state['pr']['statusCheckRollup'].pop()
        self.assertEqual(self.run_prepare().returncode, 0)

    def test_read_only_authorization_check_performs_no_github_write(self):
        (self.path / 'state.json').write_text(json.dumps(self.state))
        env = {**os.environ, 'PATH': str(self.path) + os.pathsep + os.environ['PATH'],
               'OVERRIDE_CASE': str(self.path), 'GH_AS_AUTHOR_RECORD_IDENTITY': 'nathanjohnpayne',
               'BREAK_GLASS_ADMIN': URL + '@' + HEAD,
               'MERGEPATH_OWNER_ADMIN_AUTHORIZATION': json.dumps(AUTH)}
        result = subprocess.run(['python3', str(SCRIPT), 'check', 'gh', 'pr', 'merge', '123',
                                 '--admin', '--match-head-commit', HEAD], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.path / 'posted.json').exists())

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
        collection = workflow.split('              let recordedOverride = null;', 1)[1].split('\n            }\n\n            if (violations.length', 1)[0]
        rendering = workflow.split('              if (recordedOverrides.length > 0) {', 1)[1].split('              body += `\\n---', 1)[0]
        pr = {'number': 123, 'html_url': URL, 'head': {'sha': HEAD}, 'merged_at': '2026-01-01T00:02:00Z'}
        setup = '''const context={repo:{owner:'example',repo:'repo'}};
const prViolations=[],recordedOverrides=[],violations=[];
const hadHumanHold=false,hadPolicyViolation=false,hadHumanLabel=false;
const authorIdentity='nathanjohnpayne',codexBotLogin='chatgpt-codex-connector[bot]';
const core={warning:message=>{throw new Error(message)}};
const github={rest:{issues:{listComments:'comments'},pulls:{listReviews:'reviews',listReviewComments:'inline'}},paginate:async endpoint=>endpoint==='comments'?[posted]:[]};
'''
        code = 'const pr=' + json.dumps(pr) + ',posted=' + json.dumps(posted) + ';\n' + setup
        code += '(async()=>{let recordedOverride=null;' + collection
        code += '\nlet body="";if(recordedOverrides.length>0){' + rendering
        code += '\nconsole.log(JSON.stringify({recordedOverrides,violations,body}));})().catch(e=>{console.error(e);process.exit(1)});'
        result = subprocess.run(['node', '-e', code], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report['recordedOverrides']), 1)
        self.assertEqual(report['violations'], [])
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
        for key, value in (('version', True), ('observed_codex_inflight', 'false'),
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
        self.assertFalse(override.audit(payload)['recorded_override'])
        response['user']['login'] = 'custom-codex[bot]'
        self.assertTrue(override.audit(payload)['recorded_override'])
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
        self.assertFalse(override.audit(payload)['recorded_override'])


if __name__ == '__main__':
    unittest.main()
