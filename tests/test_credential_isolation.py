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

    def test_only_known_authority_labels_are_reported_in_sorted_order(self):
        names = sorted(isolation.AUTHORITY)
        metadata = [{'name': name, 'value': 'SYNTHETIC_VALUE_NOT_FOR_REPORTING'}
                    for name in reversed(names)]
        metadata += [{'name': 'UNRELATED_BUILD_KEY', 'value': 'SYNTHETIC_VALUE_NOT_FOR_REPORTING'}]
        drift = isolation.assess(metadata, CLOSED, MAIN, 'main', metadata)
        self.assertEqual(drift, [
            'Repository-scoped authority credentials: ' + ', '.join(names),
            'Organization-shared authority credentials: ' + ', '.join(names),
        ])

    def test_repeated_authority_observations_preserve_drift_diagnostics(self):
        metadata = [{'name': 'CODEX_PAT'}, {'name': 'AUTHOR_MERGE_TOKEN'}, {'name': 'CODEX_PAT'}]
        self.assertEqual(isolation.assess(metadata, CLOSED, MAIN, 'main'), [
            'Repository-scoped authority credentials: AUTHOR_MERGE_TOKEN, CODEX_PAT, CODEX_PAT',
        ])

    def test_wildcard_tag_and_extra_branch_are_drift(self):
        for policies in ([{'name':'*','type':'branch'}], [{'name':'main','type':'tag'}],
                         MAIN + [{'name':'codex/*','type':'branch'}], []):
            self.assertTrue(isolation.assess([], CLOSED, policies, 'main'))

    def test_admin_bypass_and_unrestricted_environment_are_drift(self):
        for env in ({**CLOSED,'can_admins_bypass':True}, {**CLOSED,'deployment_branch_policy':None}):
            self.assertTrue(isolation.assess([], env, MAIN, 'main'))

    def test_expected_environment_secrets_hold_exactly_the_named_set(self):
        expected = ['DEPENDABOT_REVIEWER_TOKEN']
        self.assertEqual(isolation.assess([], CLOSED, MAIN, 'main', None,
                                          [{'name': 'DEPENDABOT_REVIEWER_TOKEN'}], expected), [])
        self.assertEqual(isolation.assess([], CLOSED, MAIN, 'main', None, [], expected),
                         ['The credential environment lacks: DEPENDABOT_REVIEWER_TOKEN'])
        drift = isolation.assess([], CLOSED, MAIN, 'main', None,
                                 [{'name': 'DEPENDABOT_REVIEWER_TOKEN'}, {'name': 'AUTHOR_MERGE_TOKEN'}], expected)
        self.assertEqual(drift, ['The credential environment holds 1 secret(s) besides the expected ones'])
        self.assertNotIn('AUTHOR_MERGE_TOKEN', json.dumps(drift))
        with self.assertRaises(ValueError):
            isolation.assess([], CLOSED, MAIN, 'main', None, None, expected)

    def test_expected_mode_requires_an_unattended_environment(self):
        expected = ['DEPENDABOT_REVIEWER_TOKEN']
        held = [{'name': 'DEPENDABOT_REVIEWER_TOKEN'}]
        def run(rules):
            return isolation.assess([], dict(CLOSED, protection_rules=rules), MAIN, 'main', None, held, expected)
        self.assertEqual(run([{'type': 'branch_policy'}, {'type': 'wait_timer', 'wait_timer': 0}]), [])
        self.assertEqual(run([{'type': 'required_reviewers', 'reviewers': []}]),
                         ['The credential environment requires reviewers, which stalls its job'])
        self.assertEqual(run([{'type': 'wait_timer', 'wait_timer': 5}]),
                         ['The credential environment has a wait timer, which delays its job'])
        for malformed in ('rules', [{}], [{'type': 'wait_timer'}]):
            with self.assertRaises(ValueError):
                run(malformed)
        # Without --expect-secrets the existing merge-queue-policy audit is unchanged.
        self.assertEqual(isolation.assess([], dict(CLOSED, protection_rules=[{'type': 'required_reviewers'}]), MAIN, 'main'), [])

    def test_dependabot_reviewer_token_shadow_is_drift(self):
        self.assertIn('DEPENDABOT_REVIEWER_TOKEN',
                      isolation.assess([{'name': 'DEPENDABOT_REVIEWER_TOKEN'}], CLOSED, MAIN, 'main')[0])

    def test_unreadable_metadata_is_error(self):
        for secrets, env, policies in ((None,CLOSED,MAIN), ([],{},MAIN), ([],CLOSED,[{}])):
            with self.assertRaises(ValueError): isolation.assess(secrets, env, policies, 'main')


class IsolationCliTests(unittest.TestCase):
    def run_audit(self, *, secrets=None, env=None, policies=None, failure=None,
                  owner_type='User', organization_secrets=None, failure_text='permission denied', inventory=None,
                  repository=None, environment='merge-queue-policy', expect=None, env_secrets=None):
        root = 'repos/owner/repo'
        observations = {
            root: [{'owner': {'type': owner_type}}] if repository is None else repository,
            root + '/actions/organization-secrets?per_page=100': organization_secrets or [{'total_count': 0, 'secrets': []}],
            root + '/environments?per_page=100': inventory or [{'total_count': 0, 'environments': []}],
            root + '/actions/secrets?per_page=100': secrets if secrets is not None else [{'total_count': 0, 'secrets': []}],
            root + '/environments/' + environment: [CLOSED] if env is None else env,
            root + '/environments/' + environment + '/deployment-branch-policies?per_page=100':
                policies if policies is not None else [{'total_count': 1, 'branch_policies': MAIN}],
            root + '/environments/' + environment + '/secrets?per_page=100':
                env_secrets if env_secrets is not None else [{'total_count': 0, 'secrets': []}],
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
            environment_vars = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ['PATH'],
                               AUDIT_CALLS=str(temp / 'calls'), AUDIT_OBSERVATIONS=str(temp / 'observations.json'),
                               AUDIT_FAILURE=failure or '', AUDIT_FAILURE_TEXT=failure_text)
            extra = ([] if environment == 'merge-queue-policy' else ['--environment', environment])
            extra += [] if expect is None else ['--expect-secrets', expect]
            result = subprocess.run(['python3', str(ROOT / 'scripts/audit-credential-isolation.py'),
                                     '--repo', 'owner/repo', '--branch', 'main', *extra], env=environment_vars,
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

    def test_dependabot_reviewer_environment_reads_back_its_secret_names(self):
        held = [{'total_count': 1, 'secrets': [{'name': 'DEPENDABOT_REVIEWER_TOKEN'}]}]
        code, report, calls = self.run_audit(environment='dependabot-reviewer',
                                             expect='DEPENDABOT_REVIEWER_TOKEN', env_secrets=held)
        self.assertEqual((code, report['status'], report['environment']), (0, 'PASS', 'dependabot-reviewer'))
        self.assertIn('repos/owner/repo/environments/dependabot-reviewer/secrets?per_page=100', calls)
        code, report, _ = self.run_audit(environment='dependabot-reviewer', expect='DEPENDABOT_REVIEWER_TOKEN')
        self.assertEqual((code, report['status']), (3, 'DRIFT'))
        self.assertIn('The credential environment lacks: DEPENDABOT_REVIEWER_TOKEN', report['drift'])
        code, report, _ = self.run_audit(environment='dependabot-reviewer', expect='DEPENDABOT_REVIEWER_TOKEN',
                                         failure='repos/owner/repo/environments/dependabot-reviewer/secrets?per_page=100')
        self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_expect_secrets_accepts_only_authority_names(self):
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/audit-credential-isolation.py'),
                                 '--repo', 'owner/repo', '--branch', 'main', '--expect-secrets', 'BUILD_KEY'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('authority credential names', result.stderr)

    def test_environment_secrets_are_not_read_without_expect(self):
        _, _, calls = self.run_audit()
        self.assertFalse(any(call.endswith('/secrets?per_page=100') and '/environments/' in call for call in calls))

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

    def test_authority_reports_omit_unrelated_metadata_on_both_output_paths(self):
        names = sorted(isolation.AUTHORITY)
        marker = 'SYNTHETIC_VALUE_NOT_FOR_REPORTING'
        metadata = [{'total_count': len(names), 'secrets': [
            {'name': name, 'value': marker, 'description': marker} for name in reversed(names)
        ]}]
        for missing in (False, True):
            with self.subTest(missing_environment=missing):
                code, report, _ = self.run_audit(
                    secrets=metadata, owner_type='Organization', organization_secrets=metadata,
                    failure='repos/owner/repo/environments/merge-queue-policy' if missing else None,
                    failure_text='gh: Not Found (HTTP 404)')
                self.assertEqual((code, report['status']), (3, 'DRIFT'))
                self.assertEqual(report['drift'][:2], [
                    'Repository-scoped authority credentials: ' + ', '.join(names),
                    'Organization-shared authority credentials: ' + ', '.join(names),
                ])
                self.assertNotIn(marker, json.dumps(report))
                self.assertEqual('The protected credential environment is missing' in report['drift'], missing)

    def test_environment_404_is_error_when_inventory_says_it_exists(self):
        code, report, _ = self.run_audit(failure='repos/owner/repo/environments/merge-queue-policy',
            failure_text='gh: Not Found (HTTP 404)',
            inventory=[{'total_count': 1, 'environments': [{'name': 'merge-queue-policy'}]}])
        self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_non_object_environment_is_structured_error(self):
        for page in (None, [], 'invalid'):
            code, report, _ = self.run_audit(env=[page])
            self.assertEqual((code, report['status']), (2, 'ERROR'))

    def test_non_object_repository_owner_is_structured_error(self):
        for owner in (None, [], 'invalid', 1, True):
            with self.subTest(owner=owner):
                code, report, calls = self.run_audit(repository=[{'owner': owner}])
                self.assertEqual((code, report['status']), (2, 'ERROR'))
                self.assertEqual(len(calls), 2)

    def test_missing_or_malformed_deployment_policy_is_structured_error(self):
        missing = {k: v for k, v in CLOSED.items() if k != 'deployment_branch_policy'}
        invalid = [missing, *[dict(CLOSED, deployment_branch_policy=policy)
                             for policy in ([], False, 'invalid', {},
                                            {'protected_branches': False, 'custom_branch_policies': 'true'})]]
        for environment in invalid:
            with self.subTest(environment=environment):
                code, report, calls = self.run_audit(env=[environment])
                self.assertEqual((code, report['status']), (2, 'ERROR'))
                self.assertEqual(len(calls), 3)

    def test_non_main_policy_on_second_page_is_drift(self):
        code, report, _ = self.run_audit(policies=[
            {'total_count': 2, 'branch_policies': MAIN},
            {'total_count': 2, 'branch_policies': [{'name': 'feature/*', 'type': 'branch'}]},
        ])
        self.assertEqual((code, report['status']), (3, 'DRIFT'))
        self.assertTrue(any('literal default branch' in drift for drift in report['drift']))

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
