#!/usr/bin/env python3
"""Fake-only source boundaries and the existing publisher's causal hold receipt."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HEAD = 'a' * 40


def workflow(name):
    try:
        import yaml
    except ImportError:
        pass
    else:
        return yaml.safe_load((ROOT / '.github/workflows' / name).read_text())
    return json.loads(subprocess.check_output(
        ['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.dump(YAML.load_file(ARGV[0]))',
         str(ROOT / '.github/workflows' / name)], text=True))


class CausalHold(unittest.TestCase):
    def probe(self, marker=None, status='in_progress', conclusion=None, suite=20, own=True, fail=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            stub = path / 'gh'
            stub.write_text('#!/bin/sh\n[ "$FAIL" != true ] || exit 1\nprintf "%s\\n" "$RUNS"\n')
            stub.chmod(0o755)
            rows = [dict(id=9, status=status, conclusion=conclusion, ext='', suite=suite,
                         app='github-actions', url='', summary=marker)]
            if own:
                rows.append(dict(id=5, status='in_progress', conclusion=None, ext='own', suite=10,
                                 app='github-actions', url='https://github.com/o/r/actions/runs/777/job/5'))
            env = {'PATH': directory + os.pathsep + os.environ['PATH'], 'HOME': directory,
                   'GH_TOKEN': 'fake-source-boundary', 'FAIL': str(fail).lower(),
                   'RUNS': '\n'.join(json.dumps(row) for row in rows)}
            return subprocess.run([str(ROOT / 'scripts/gate-api-lineage-blocking.sh'),
                                   'o/r', HEAD, 'Merge clearance gate', '777', '2'],
                                  env=env, capture_output=True, text=True, timeout=10).returncode

    @staticmethod
    def receipt(run='777', attempt='2', head=HEAD):
        return f'Publisher phase 1: evaluation queued for {head}. <!-- required-check-publisher:pending:{run}:{attempt} -->'

    def test_current_parent_hold_positive(self):
        self.assertEqual(self.probe(self.receipt()), 0)

    def test_missing_historical_or_rebound_receipt_fails_native(self):
        for marker in [None, '', self.receipt(run='776'), self.receipt(attempt='1'),
                       self.receipt(head='b' * 40), 'old failure']:
            with self.subTest(marker=marker):
                self.assertEqual(self.probe(marker, status='completed', conclusion='failure'), 1)

    def test_original_blocking_and_suite_guards_remain(self):
        for options in [dict(status='completed', conclusion='success'), dict(suite=10),
                        dict(own=False), dict(fail=True)]:
            with self.subTest(options=options):
                self.assertEqual(self.probe(self.receipt(), **options), 1)

    def test_native_mcg_always_supplies_parent_attempt(self):
        job = workflow('merge-clearance-gate.yml')['jobs']['merge-clearance-gate']
        self.assertTrue(all(value == 'read' for value in job['permissions'].values()))
        step = next(step for step in job['steps'] if step.get('id') == 'lineage')
        self.assertEqual(step['env']['RUN_ID'], '${{ github.run_id }}')
        self.assertEqual(step['env']['RUN_ATTEMPT'], '${{ github.run_attempt }}')
        self.assertIn('"$RUN_ID" "$RUN_ATTEMPT"', step['run'])
        self.assertNotIn('check-runs', '\n'.join(step.get('run', '') for step in job['steps']))


class CredentialDestinations(unittest.TestCase):
    def test_recovery_authority_is_only_trusted_actions_rerun(self):
        document = workflow('required-check-publisher.yml')
        job = document['jobs']['recover-native-clearance']
        self.assertEqual(job['permissions']['actions'], 'write')
        self.assertEqual(job['permissions']['checks'], 'read')
        self.assertNotIn('environment', job)
        self.assertNotIn('workflow_dispatch', document.get('on', document.get(True, {})))
        self.assertNotIn('secrets.', json.dumps(job))
        checkout = next(s for s in job['steps'] if 'checkout@' in s.get('uses', ''))
        self.assertEqual(checkout['with']['ref'], '${{ github.event.repository.default_branch }}')
        self.assertFalse(checkout['with']['persist-credentials'])

    def test_completed_partial_batch_can_deliver_only_recorded_protected_pairs(self):
        jobs = workflow('auto-clear-blocking-labels.yml')['jobs']
        for parent, child in [('evaluate-and-clear', 'clear-event-labels'),
                              ('scheduled-sweep', 'clear-sweep-labels')]:
            condition = jobs[child]['if']
            self.assertIn('!cancelled()', condition)
            self.assertIn('contains(fromJSON(\'["success","failure"]\'), needs.' + parent + '.result)', condition)
            self.assertIn('needs.' + parent + '.outputs.protected_pairs', condition)

    def test_review_chain_nomination_survives_empty_associations(self):
        resolver = next(s for s in workflow('auto-clear-blocking-labels.yml')['jobs']['evaluate-and-clear']['steps']
                        if s.get('id') == 'pr')['run']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            stub = path / 'gh'
            stub.write_text('#!/bin/sh\ncase "$*" in\n  *actions/runs/42*) echo "$SOURCE_TITLE";;\n  *"pr list"*) echo "[]";;\n  *) exit 90;;\nesac\n')
            stub.chmod(0o755)
            for title, expected in [(f'review-v1 pr=7 review=9 head={HEAD} base={"b" * 40}', '7'),
                                    ('invalid source', '')]:
                output = path / 'output'
                output.write_text('')
                event = dict(workflow_run=dict(conclusion='success', pull_requests=[], head_sha='d' * 40,
                             path='.github/workflows/agent-review.yml', event='workflow_run',
                             display_title='policy-v1 pr=0 source=42'))
                result = subprocess.run(['bash', '-c', resolver], timeout=10, capture_output=True, text=True,
                    env=dict(PATH=directory + os.pathsep + os.environ['PATH'], REPO='o/r',
                             EVENT_NAME='workflow_run', EVENT_JSON=json.dumps(event),
                             GITHUB_OUTPUT=str(output), SOURCE_TITLE=title))
                self.assertEqual(result.returncode, 0, result.stderr)
                if expected:
                    self.assertIn('\n7\n', output.read_text())
                else:
                    self.assertEqual(output.read_text(), 'numbers=\n')

    def test_maintenance_destinations(self):
        for name, job, environment in [
            ('daily-feedback-rollup', 'rollup', 'reviewer-maintenance'),
            ('pr-audit', 'audit', 'reviewer-maintenance'),
            ('weekly-drift-audit', 'audit', 'reviewer-maintenance'),
            ('weekly-feedback-sweep', 'sweep', 'reviewer-maintenance'),
            ('thread-resolution-lane', 'resolve', 'reviewer-maintenance'),
            ('branch-protection-audit', 'audit', 'branch-protection-audit'),
            ('onepassword-headless-proof', 'op-service-account-proof', 'onepassword-proof')]:
            # These hub maintenance workflows are optional consumer carriers;
            # assert their destination whenever they are actually installed.
            if not (ROOT / '.github/workflows' / (name + '.yml')).exists():
                self.assertIn(name, {'weekly-drift-audit', 'weekly-feedback-sweep',
                                     'branch-protection-audit', 'onepassword-headless-proof'})
                continue
            with self.subTest(workflow=name):
                self.assertEqual(workflow(name + '.yml')['jobs'][job]['environment'], environment)

    def test_auto_clear_transport_has_no_authority_credential(self):
        jobs = workflow('auto-clear-blocking-labels.yml')['jobs']
        for parent, child, stepid in [('evaluate-and-clear', 'clear-event-labels', 'clear'),
                                      ('scheduled-sweep', 'clear-sweep-labels', 'sweep')]:
            with self.subTest(parent=parent):
                self.assertEqual(jobs[parent]['environment'], 'merge-queue-policy')
                self.assertEqual(jobs[child]['environment'], 'review-automation')
                self.assertEqual(set(jobs[parent]['outputs']), {'candidate_prs', 'protected_pairs'})
                self.assertEqual(jobs[parent]['outputs']['protected_pairs'],
                                 '${{ steps.' + stepid + '.outputs.protected_pairs }}')
                source = json.dumps(jobs[child])
                for forbidden in ['AUTHOR_MERGE_TOKEN', 'MERGE_QUEUE_POLICY_TOKEN',
                                  'MERGE_QUEUE_SOURCE_TOKEN', 'REVIEWER_ASSIGNMENT_TOKEN', 'CI_ACTOR_TOKEN']:
                    self.assertNotIn(forbidden, source)
                self.assertIn('PROTECTED_PAIRS', source)
                action = next(step for step in jobs[child]['steps'] if step.get('id') == 'automation')
                self.assertEqual(action['with']['repositories'], '${{ github.event.repository.name }}')

    def test_candidate_jobs_have_only_read_access_and_no_standing_secrets(self):
        selected = [('pr-review-policy.yml', ['self-review-check', 'label-gate', 'external-review-labeling']),
                    ('agent-review-events.yml', ['signal']),
                    ('merge-clearance-gate.yml', ['merge-clearance-gate']),
                    ('coderabbit-severity-gate.yml', ['coderabbit-severity-gate']),
                    ('codex-p1-gate.yml', ['archive-edited-feedback', 'codex-p1-gate'])]
        for name, names in selected:
            document = workflow(name)
            for name_job in names:
                with self.subTest(workflow=name, job=name_job):
                    job = document['jobs'][name_job]
                    permissions = job.get('permissions', document.get('permissions', {}))
                    self.assertTrue(permissions)
                    self.assertTrue(all(value == 'read' for value in permissions.values()))
                    self.assertLessEqual(set(re.findall(r'secrets\.([A-Za-z0-9_]+)', json.dumps(job))), {'GITHUB_TOKEN'})


if __name__ == '__main__':
    unittest.main()
