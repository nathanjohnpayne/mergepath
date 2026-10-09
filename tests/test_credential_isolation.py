#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('isolation', ROOT / 'scripts/audit-credential-isolation.py')
isolation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolation)
CLOSED = {'can_admins_bypass': False, 'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}}
MAIN = [{'name': 'main', 'type': 'branch'}]


class IsolationTests(unittest.TestCase):
    def test_isolated_environment_passes(self):
        self.assertEqual(isolation.assess([{'name':'UNRELATED_BUILD_KEY'}], CLOSED, MAIN, 'main'), [])

    def test_each_repository_authority_secret_is_drift(self):
        for name in isolation.AUTHORITY:
            self.assertIn(name, isolation.assess([{'name':name}], CLOSED, MAIN, 'main')[0])

    def test_merge_queue_tokens_are_authority_credentials(self):
        for name in ('MERGE_QUEUE_POLICY_TOKEN', 'MERGE_QUEUE_SOURCE_TOKEN'):
            self.assertTrue(isolation.assess([{'name':name}], CLOSED, MAIN, 'main'))

    def test_wildcard_tag_and_extra_branch_are_drift(self):
        for policies in ([{'name':'*','type':'branch'}], [{'name':'main','type':'tag'}],
                         MAIN + [{'name':'codex/*','type':'branch'}], []):
            self.assertTrue(isolation.assess([], CLOSED, policies, 'main'))

    def test_admin_bypass_and_unrestricted_environment_are_drift(self):
        for env in ({**CLOSED,'can_admins_bypass':True}, {**CLOSED,'deployment_branch_policy':None}):
            self.assertTrue(isolation.assess([], env, MAIN, 'main'))

    def test_unreadable_metadata_is_error(self):
        for secrets, env, policies in ((None,CLOSED,MAIN), ([],{},MAIN), ([],CLOSED,[{}])):
            with self.assertRaises(ValueError): isolation.assess(secrets, env, policies, 'main')


class IsolationCliTests(unittest.TestCase):
    def run_audit(self, *, secrets=None, env=None, policies=None, failure=None,
                  owner_type='User', organization_secrets=None, failure_text='permission denied', inventory=None):
        root = 'repos/owner/repo'
        observations = {
            root: [{'owner': {'type': owner_type}}],
            root + '/actions/organization-secrets?per_page=100': organization_secrets or [{'total_count': 0, 'secrets': []}],
            root + '/environments?per_page=100': inventory or [{'total_count': 0, 'environments': []}],
            root + '/actions/secrets?per_page=100': secrets if secrets is not None else [{'total_count': 0, 'secrets': []}],
            root + '/environments/merge-queue-policy': [CLOSED] if env is None else env,
            root + '/environments/merge-queue-policy/deployment-branch-policies?per_page=100':
                policies if policies is not None else [{'total_count': 1, 'branch_policies': MAIN}],
        }
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / 'observations.json').write_text(json.dumps(observations))
            gh = temp / 'gh'
            gh.write_text('#!/usr/bin/env python3\n' + r'''
import json, os, sys
from pathlib import Path
assert sys.argv[1:4] == ['api', '--paginate', '--slurp'], sys.argv
path = sys.argv[4]
with open(os.environ['AUDIT_CALLS'], 'a') as log:
    log.write(path + '\n')
if path == os.environ.get('AUDIT_FAILURE'):
    sys.stderr.write(os.environ['AUDIT_FAILURE_TEXT'] + '\n')
    raise SystemExit(1)
print(json.dumps(json.loads(Path(os.environ['AUDIT_OBSERVATIONS']).read_text())[path]))
''')
            gh.chmod(0o755)
            environment = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ['PATH'],
                               AUDIT_CALLS=str(temp / 'calls'), AUDIT_OBSERVATIONS=str(temp / 'observations.json'),
                               AUDIT_FAILURE=failure or '', AUDIT_FAILURE_TEXT=failure_text)
            result = subprocess.run(['python3', str(ROOT / 'scripts/audit-credential-isolation.py'),
                                     '--repo', 'owner/repo', '--branch', 'main'], env=environment,
                                    text=True, capture_output=True)
            calls = (temp / 'calls').read_text().splitlines()
            return result.returncode, json.loads(result.stdout), calls

    def test_complete_paginated_metadata_detects_secret_on_second_page(self):
        code, report, calls = self.run_audit(secrets=[
            {'total_count': 2, 'secrets': [{'name': 'BUILD_KEY'}]},
            {'total_count': 2, 'secrets': [{'name': 'AUTHOR_MERGE_TOKEN'}]},
        ])
        self.assertEqual(code, 3)
        self.assertEqual(report['status'], 'DRIFT')
        self.assertIn('AUTHOR_MERGE_TOKEN', report['drift'][0])
        self.assertEqual(len(calls), 4)

    def test_isolated_environment_cli_passes(self):
        code, report, calls = self.run_audit()
        self.assertEqual((code, report['status']), (0, 'PASS'))
        self.assertEqual(len(calls), 4)

    def test_unrestricted_environment_is_drift_without_reading_404_endpoint(self):
        code, report, calls = self.run_audit(env=[dict(CLOSED, deployment_branch_policy=None)])
        self.assertEqual((code, report['status']), (3, 'DRIFT'))
        self.assertEqual(len(calls), 3)

    def test_missing_or_inconsistent_pagination_is_error(self):
        for pages in ([{'total_count': 2, 'secrets': []}],
                      [{'total_count': 0, 'secrets': []}, {'total_count': 1, 'secrets': []}],
                      [{'secrets': []}]):
            code, report, calls = self.run_audit(secrets=pages)
            self.assertEqual((code, report['status']), (2, 'ERROR'))
            self.assertEqual(len(calls), 1)

    def test_unreadable_required_metadata_is_error(self):
        for suffix in ('/actions/secrets?per_page=100', '/environments/merge-queue-policy',
                       '/environments/merge-queue-policy/deployment-branch-policies?per_page=100'):
            code, report, _ = self.run_audit(failure='repos/owner/repo' + suffix)
            self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_organization_shared_authority_secret_is_drift(self):
        code, report, calls = self.run_audit(owner_type='Organization', organization_secrets=[
            {'total_count': 2, 'secrets': [{'name': 'BUILD_KEY'}]},
            {'total_count': 2, 'secrets': [{'name': 'MERGE_QUEUE_POLICY_TOKEN'}]},
        ])
        self.assertEqual((code, report['status']), (3, 'DRIFT'))
        self.assertIn('Organization-shared', report['drift'][0])
        self.assertIn('MERGE_QUEUE_POLICY_TOKEN', report['drift'][0])
        self.assertIn('repos/owner/repo/actions/organization-secrets?per_page=100', calls)

    def test_unreadable_or_incomplete_organization_inventory_is_error(self):
        code, report, _ = self.run_audit(owner_type='Organization',
            failure='repos/owner/repo/actions/organization-secrets?per_page=100')
        self.assertEqual((code, report['status']), (2, 'ERROR'))
        code, report, _ = self.run_audit(owner_type='Organization', organization_secrets=[{'total_count': 1, 'secrets': []}])
        self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_confirmed_missing_environment_is_drift(self):
        code, report, _ = self.run_audit(failure='repos/owner/repo/environments/merge-queue-policy',
            failure_text='gh: Not Found (HTTP 404)')
        self.assertEqual((code, report['status']), (3, 'DRIFT'))
        self.assertIn('missing', report['drift'][0])

    def test_environment_404_is_error_when_inventory_says_it_exists(self):
        code, report, _ = self.run_audit(failure='repos/owner/repo/environments/merge-queue-policy',
            failure_text='gh: Not Found (HTTP 404)',
            inventory=[{'total_count': 1, 'environments': [{'name': 'merge-queue-policy'}]}])
        self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_non_object_environment_is_structured_error(self):
        for page in (None, [], 'invalid'):
            code, report, _ = self.run_audit(env=[page])
            self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_missing_gh_is_structured_error(self):
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/audit-credential-isolation.py'),
                                 '--repo', 'owner/repo', '--branch', 'main'],
                                env=dict(os.environ, PATH='/nonexistent'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['status'], 'ERROR')
        self.assertNotIn('Traceback', result.stderr)

    def test_unreadable_bypass_field_is_error(self):
        code, report, _ = self.run_audit(env=[{'deployment_branch_policy': None}])
        self.assertEqual((code, report['status']), (2, 'ERROR'))


if __name__ == '__main__': unittest.main()
