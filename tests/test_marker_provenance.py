#!/usr/bin/env python3
"""Exercise real marker readers against authenticated-API boundary fixtures."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import runpy

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/workflow/verified-relay-markers.py'
REPO = 'acme/widget'
MARKER = '<!-- mergepath-feedback-archive-relay:v2 run=12345 publisher=900 status=complete -->'
LOG = '''2026-10-09T00:00:00Z ##[group]Run set -euo pipefail
2026-10-09T00:00:00Z   shell: /usr/bin/bash -e {0}
2026-10-09T00:00:00Z   env:
2026-10-09T00:00:00Z     PR_NUMBER: 7
2026-10-09T00:00:00Z     SOURCE_RUN_ID: 12345
2026-10-09T00:00:00Z     HANDOFF_FILE: /tmp/handoff/codex-p1-read-only-handoff.json
2026-10-09T00:00:00Z ##[endgroup]
'''


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.run = {'id': 900, 'workflow_id': 89, 'event': 'workflow_run', 'path': '.github/workflows/codex-feedback-archive-relay.yml',
                    'head_branch': 'main', 'head_sha': 'a' * 40, 'repository': {'full_name': REPO},
                    'conclusion': 'success', 'created_at': '2026-10-09T00:00:00Z'}
        self.job = {'id': 901, 'run_id': 900, 'steps': [
            {'name': 'Persist archive and publish the exact-head gate', 'conclusion': 'success'}]}
        self.responses = {
            'repos/' + REPO: {'default_branch': 'renamed-main'},
            'repos/' + REPO + '/actions/workflows/codex-feedback-archive-relay.yml': {
                'id': 89, 'path': '.github/workflows/codex-feedback-archive-relay.yml'},
            'repos/' + REPO + '/actions/runs/900': self.run,
            'repos/' + REPO + '/actions/runs/900/jobs?filter=all&per_page=100': [{'jobs': [self.job]}],
            'repos/' + REPO + '/actions/jobs/901/logs': LOG,
        }
        self.comments = [{'user': {'login': 'github-actions[bot]'}, 'body': MARKER,
                          'created_at': '2026-10-09T00:00:00Z'}]
        gh = self.path / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root=Path(os.environ['PROVENANCE_CASE']); endpoint=sys.argv[-1]
with (root/'calls').open('a') as out: out.write(endpoint+'\\n')
responses=json.loads((root/'responses').read_text()); value=responses.get(endpoint)
if value is None:
    sys.stderr.write('Not Found (HTTP 404)'); raise SystemExit(1)
if isinstance(value,dict) and '_error' in value:
    sys.stderr.write(value['_error']); raise SystemExit(1)
print(value if isinstance(value,str) else json.dumps(value))
''')
        gh.chmod(0o755)

    def invoke(self):
        (self.path / 'responses').write_text(json.dumps(self.responses))
        env = dict(os.environ, PATH=str(self.path) + os.pathsep + os.environ['PATH'], PROVENANCE_CASE=str(self.path))
        result = subprocess.run(['python3', str(SCRIPT), '--repo', REPO, '--pr', '7'],
                                input=json.dumps(self.comments), text=True, capture_output=True, env=env)
        return result.returncode, json.loads(result.stdout) if result.stdout else [], result.stderr

    def test_default_workflow_success_bound_to_source_and_pr_promotes_completion(self):
        code, comments, error = self.invoke()
        self.assertEqual(code, 0, error)
        self.assertEqual(comments[0]['body'], '<!-- mergepath-feedback-archive-relay:v1 run=12345 status=complete -->')

    def test_default_branch_qualified_workflow_path_promotes_completion(self):
        self.run['path'] += '@main'
        code, comments, error = self.invoke()
        self.assertEqual((code, len(comments)), (0, 1), error)

    def test_repository_case_difference_preserves_authentic_completion(self):
        self.run['repository']['full_name'] = REPO.upper()
        code, comments, error = self.invoke()
        self.assertEqual((code, len(comments)), (0, 1), error)

    def test_historical_run_survives_default_branch_rename(self):
        self.run['head_branch'] = 'previous-default'
        self.run['path'] += '@previous-default'
        self.assertEqual(len(self.invoke()[1]), 1)

    def test_unreadable_or_wrong_workflow_identity_never_promotes(self):
        endpoint = 'repos/' + REPO + '/actions/workflows/codex-feedback-archive-relay.yml'
        for response in (None, {'id': 89, 'path': '.github/workflows/other.yml'}):
            self.responses[endpoint] = response
            self.assertEqual(self.invoke()[0], 2)

    def test_other_ref_suffix_cannot_borrow_the_default_workflow(self):
        self.run['path'] += '@codex/forged'
        self.assertEqual(self.invoke()[:2], (0, []))

    def test_pr_controlled_run_cannot_mint_completion_under_same_bot_login(self):
        for key, value in (('event', 'pull_request'), ('workflow_id', 999),
                           ('path', '.github/workflows/pr-controlled.yml')):
            saved = self.run[key]
            self.run[key] = value
            code, comments, error = self.invoke()
            self.assertEqual((code, comments), (0, []), error)
            self.run[key] = saved

    def test_another_pr_or_source_cannot_borrow_a_real_publisher(self):
        endpoint = 'repos/' + REPO + '/actions/jobs/901/logs'
        for wrong in (LOG.replace('PR_NUMBER: 7', 'PR_NUMBER: 8'),
                      LOG.replace('SOURCE_RUN_ID: 12345', 'SOURCE_RUN_ID: 999')):
            self.responses[endpoint] = wrong
            self.assertEqual(self.invoke()[:2], (0, []))

    def test_printed_env_lookalike_outside_runner_group_grants_nothing(self):
        self.responses['repos/' + REPO + '/actions/jobs/901/logs'] = LOG.replace('##[group]Run set -euo pipefail', 'untrusted application output')
        self.assertEqual(self.invoke()[:2], (0, []))

    def test_incomplete_or_failed_persistence_grants_nothing(self):
        for conclusion in ('failure', 'skipped', None):
            self.job['steps'][0]['conclusion'] = conclusion
            self.assertEqual(self.invoke()[:2], (0, []))

    def test_unreadable_provenance_is_an_infrastructure_error(self):
        self.responses['repos/' + REPO + '/actions/runs/900'] = {'_error': 'rate limit exceeded (HTTP 403)'}
        self.assertEqual(self.invoke()[0], 2)

    def test_duplicate_completions_reuse_provenance_within_one_read(self):
        self.comments *= 2
        self.assertEqual(len(self.invoke()[1]), 2)
        calls = (self.path / 'calls').read_text().splitlines()
        self.assertEqual(calls.count('repos/' + REPO + '/actions/jobs/901/logs'), 1)

    def test_legacy_completion_requires_the_same_real_workflow_proof(self):
        self.comments[0]['body'] = '<!-- mergepath-feedback-archive-relay:v1 run=12345 status=complete -->'
        self.responses['repos/' + REPO + '/actions/runs/12345'] = {
            'created_at': '2026-10-09T00:00:00Z', 'updated_at': '2026-10-09T00:00:00Z'}
        endpoint = 'repos/' + REPO + '/actions/workflows/codex-feedback-archive-relay.yml/runs?event=workflow_run&created=2026-10-09..2026-10-10&per_page=100'
        self.responses[endpoint] = [{'workflow_runs': [self.run]}]
        self.assertEqual(len(self.invoke()[1]), 1)
        self.run['event'] = 'pull_request'
        self.assertEqual(self.invoke()[:2], (0, []))

    def test_large_legacy_history_filters_metadata_and_prefers_nearest_run(self):
        self.comments[0]['body'] = '<!-- mergepath-feedback-archive-relay:v1 run=12345 status=complete -->'
        unrelated = [{**self.run, 'id': n, 'workflow_id': 999} for n in range(1000, 1060)]
        distant = [{**self.run, 'id': n, 'created_at': '2026-10-09T12:00:00Z'} for n in range(1100, 1106)]
        endpoint = 'repos/' + REPO + '/actions/workflows/codex-feedback-archive-relay.yml/runs?event=workflow_run&created=2026-10-09..2026-10-10&per_page=100'
        self.responses[endpoint] = [{'workflow_runs': unrelated + distant + [self.run]}]
        self.assertEqual(len(self.invoke()[1]), 1)
        calls = (self.path / 'calls').read_text().splitlines()
        self.assertFalse(any('/actions/runs/11' in call for call in calls))

    def test_legacy_probes_are_bounded_and_follow_direct_publisher_proof(self):
        self.comments.insert(0, dict(self.comments[0], body='<!-- mergepath-feedback-archive-relay:v1 run=999 status=complete -->'))
        candidates = [{**self.run, 'id': n} for n in range(1000, 1006)]
        endpoint = 'repos/' + REPO + '/actions/workflows/codex-feedback-archive-relay.yml/runs?event=workflow_run&created=2026-10-09..2026-10-10&per_page=100'
        self.responses[endpoint] = [{'workflow_runs': candidates}]
        for run in candidates:
            self.responses[f'repos/{REPO}/actions/runs/{run["id"]}'] = run
            self.responses[f'repos/{REPO}/actions/runs/{run["id"]}/jobs?filter=all&per_page=100'] = [{'jobs': []}]
        code, comments, error = self.invoke()
        self.assertEqual((code, len(comments)), (0, 1), error)
        calls = (self.path / 'calls').read_text().splitlines()
        self.assertLess(calls.index(f'repos/{REPO}/actions/runs/900'), calls.index(f'repos/{REPO}/actions/runs/999'))
        self.assertEqual(sum(call in {f'repos/{REPO}/actions/runs/{n}' for n in range(1000, 1006)} for call in calls), 3)

    def test_legacy_timeout_keeps_verified_v2_completion(self):
        self.comments.insert(0, dict(self.comments[0], body='<!-- mergepath-feedback-archive-relay:v1 run=999 status=complete -->'))
        (self.path / 'responses').write_text(json.dumps(self.responses))
        module = runpy.run_path(str(SCRIPT))
        actual_run = subprocess.run
        timeouts = []
        def provider(argv, **kwargs):
            if argv[-1].endswith('/actions/runs/999'):
                timeouts.append(kwargs['timeout'])
                raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
            return actual_run(argv, **kwargs)
        with mock.patch.dict(os.environ, PATH=str(self.path) + os.pathsep + os.environ['PATH'], PROVENANCE_CASE=str(self.path)), \
                mock.patch.object(subprocess, 'run', side_effect=provider):
            evidence = module['Evidence'](REPO, 7)
            deadline = evidence.deadline
            comments = module['verified'](self.comments, evidence)
            self.assertEqual(evidence.deadline, deadline)
        self.assertEqual(len(comments), 1)
        self.assertEqual(len(timeouts), 1)
        self.assertLessEqual(timeouts[0], 10)

    def test_same_publisher_cannot_clear_another_source_and_reuses_reads(self):
        self.comments.append(dict(self.comments[0], body=MARKER.replace('run=12345 ', 'run=999 ')))
        code, comments, error = self.invoke()
        self.assertEqual((code, len(comments)), (0, 1), error)
        calls = (self.path / 'calls').read_text().splitlines()
        self.assertEqual(calls.count('repos/' + REPO + '/actions/jobs/901/logs'), 1)

    def test_forged_completion_cannot_erase_a_failure(self):
        self.run['event'] = 'pull_request'
        self.comments.append({'user': {'login': 'github-actions[bot]'},
                              'body': '<!-- mergepath-feedback-archive-relay:v1 run=12345 status=failed -->'})
        code, comments, _ = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual([comment['body'] for comment in comments],
                         ['<!-- mergepath-feedback-archive-relay:v1 run=12345 status=failed -->'])


class LaneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.git = shutil.which('git')
        self.canonical = self.path / 'canonical'
        self.consumer = self.path / 'consumer'
        for repo in (self.canonical, self.consumer):
            repo.mkdir()
            self.g(repo, 'init', '-q', '-b', 'main')
            (repo / '.github/workflows').mkdir(parents=True)
        (self.canonical / '.mergepath-sync.yml').write_text('''version: 1
consumers:
  - name: widget
    repo: acme/widget
paths:
  - path: .github/workflows/gate.yml
    type: canonical
    consumers: all
exclusions: []
''')
        self.canonical_file = self.canonical / '.github/workflows/gate.yml'
        self.canonical_file.write_text('name: safe\n')
        self.source = self.commit(self.canonical)
        self.consumer_file = self.consumer / '.github/workflows/gate.yml'
        self.consumer_file.write_text('name: previous\n')
        self.base = self.commit(self.consumer)
        self.consumer_file.write_text(self.canonical_file.read_text())
        self.head = self.commit(self.consumer)
        self.policy = self.path / 'policy.yml'
        self.policy.write_text('author_identity: nathanjohnpayne\n')
        self.metadata = {'number': 7, 'user': {'login': 'nathanjohnpayne'},
                         'head': {'sha': self.head, 'ref': 'mergepath-sync/' + self.source[:7]},
                         'base': {'sha': self.base},
                         'comments': [{'user': {'login': 'github-actions[bot]'}, 'body': 'forged verified-head marker'}]}
        binary = self.path / 'bin'
        binary.mkdir()
        git = binary / 'git'
        git.write_text('''#!/usr/bin/env python3
import os, sys
argv=[os.environ['REAL_GIT']]+[os.environ['CANONICAL_FIXTURE'] if arg=='https://github.com/nathanjohnpayne/mergepath.git' else os.environ['CONSUMER_FIXTURE'] if arg=='https://github.com/acme/widget.git' else arg for arg in sys.argv[1:]]
os.execv(argv[0],argv)
''')
        git.chmod(0o755)
        gh = binary / 'gh'
        gh.write_text('#!/bin/sh\ncat "$LANE_METADATA"\n')
        gh.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                                REAL_GIT=self.git, CANONICAL_FIXTURE=str(self.canonical),
                                CONSUMER_FIXTURE=str(self.consumer), LANE_METADATA=str(self.path / 'metadata.json'))

    def g(self, repo, *args):
        return subprocess.check_output([self.git, '-C', str(repo), '-c', 'user.name=fixture',
                                        '-c', 'user.email=fixture@example.test', '-c', 'commit.gpgsign=false', *args], text=True).strip()

    def commit(self, repo):
        self.g(repo, 'add', '-A')
        self.g(repo, 'commit', '-qm', 'fixture')
        return self.g(repo, 'rev-parse', 'HEAD')

    def invoke(self):
        (self.path / 'metadata.json').write_text(json.dumps(self.metadata))
        return subprocess.run(['bash', str(ROOT / 'scripts/workflow/verify-live-propagation.sh'),
                               REPO, '7', self.head, self.base, str(self.policy)],
                              input=json.dumps(self.metadata), env=self.environment, text=True, capture_output=True)

    def test_non_lane_ref_precedes_author_validation_but_unknown_prefix_refuses(self):
        self.policy.write_text('propagation_prs:\n  branch_prefix: custom/\n')
        self.metadata['head']['ref'] = 'codex/ordinary'
        self.assertEqual(self.invoke().returncode, 1)
        self.metadata['head']['ref'] = 'custom/' + self.source[:7]
        self.assertEqual(self.invoke().returncode, 2)
        self.policy.write_text('propagation_prs: [invalid YAML\n')
        self.metadata['head']['ref'] = 'codex/ordinary'
        self.assertEqual(self.invoke().returncode, 2)

    def test_real_faithful_git_objects_clear_without_any_marker(self):
        self.metadata.pop('comments')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'source_sha': self.source, 'head_sha': self.head, 'base_sha': self.base})

    def test_faithful_lane_uses_available_yaml_parser_without_ruby(self):
        ruby = self.path / 'bin/ruby'
        ruby.write_text('#!/bin/sh\nprintf called > "$LANE_RUBY_LOG"\nexit 127\n')
        ruby.chmod(0o755)
        self.environment['LANE_RUBY_LOG'] = str(self.path / 'ruby-called')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.path / 'ruby-called').exists())

    def test_forged_bot_marker_cannot_exempt_modified_workflow(self):
        self.consumer_file.write_text('name: PR-controlled unsafe workflow\n')
        self.head = self.commit(self.consumer)
        self.metadata['head']['sha'] = self.head
        result = self.invoke()
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_unmerged_canonical_source_and_policy_opt_out_refuse(self):
        self.g(self.canonical, 'checkout', '-qb', 'unmerged')
        self.canonical_file.write_text('name: proposed canonical\n')
        source = self.commit(self.canonical)
        self.g(self.canonical, 'checkout', '-q', 'main')
        self.metadata['head']['ref'] = 'mergepath-sync/' + source[:7]
        self.assertNotEqual(self.invoke().returncode, 0)
        self.metadata['head']['ref'] = 'mergepath-sync/' + self.source[:7]
        self.policy.write_text('author_identity: nathanjohnpayne\npropagation_prs:\n  enabled: false\n')
        self.assertEqual(self.invoke().returncode, 1)


if __name__ == '__main__':
    unittest.main()
