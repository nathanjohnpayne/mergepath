#!/usr/bin/env python3
"""Fake GitHub evidence exercises the actual option-B recovery writer."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('recovery', ROOT / 'scripts/workflow/recover-native-clearance.py')
recovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recovery)
A, B, R, M = [''.join(c for _ in range(40)) for c in 'abdc']


class NativeRecovery(unittest.TestCase):
    def setUp(self):
        self.nomination = dict(pr=7, head=A, base=B, revision=R, generation=30)
        self.pr = dict(number=7, state='open', head=dict(sha=A, ref='feature', repo=dict(id=2)),
                       base=dict(sha=B, repo=dict(id=1, full_name='owner/repo')))
        binding = dict(repo='owner/repo', pr=7, head=A, context=recovery.CONTEXT, trusted_revision=R)
        self.green = dict(id=30, name=recovery.CONTEXT, status='completed', conclusion='success',
                          head_sha=A, external_id='', app=dict(slug='github-actions'),
                          output=dict(summary='<!-- mergepath-generation:v1 ' + json.dumps(binding) + ' -->'))
        self.native = dict(id=40, name=recovery.CONTEXT, status='completed', conclusion='failure',
                           head_sha=A, external_id='native-uuid', app=dict(slug='github-actions'),
                           details_url='https://github.com/owner/repo/actions/runs/50/job/60')
        self.run = dict(id=50, repository=dict(id=1), path=recovery.WORKFLOW, event='pull_request',
                        head_repository=dict(id=2), head_branch='feature', head_sha=M,
                        pull_requests=[dict(number=7, head=dict(sha=A), base=dict(sha=B))],
                        status='completed', run_attempt=1, workflow_id=70)
        self.job = dict(id=60, run_id=50, name=recovery.CONTEXT, status='completed', conclusion='failure',
                        check_run_url='https://api.github.com/repos/owner/repo/check-runs/40')
        self.commit = dict(sha=M, parents=[dict(sha=B), dict(sha=A)])
        self.writes = []
        self.reads = []
        self.pass_ = True
        self.drift = None

    def api(self, repo, suffix, *, method='GET', paginate=False):
        self.assertEqual(repo, 'owner/repo')
        if method != 'GET':
            self.writes.append((method, suffix))
            self.assertEqual(method, 'POST')
            self.assertEqual(suffix, 'actions/jobs/60/rerun')
            return None
        self.reads.append(suffix)
        if suffix == 'pulls/7':
            return copy.deepcopy(self.pr)
        if suffix == 'commits/HEAD':
            return dict(sha=R)
        if '/check-runs?' in suffix:
            self.assertTrue(paginate)
            return [dict(check_runs=[copy.deepcopy(self.green), copy.deepcopy(self.native)])]
        if suffix == 'actions/runs/50':
            return copy.deepcopy(self.run)
        if suffix == f'git/commits/{M}':
            return copy.deepcopy(self.commit)
        if suffix == 'actions/runs/50/attempts/1/jobs?per_page=100':
            self.assertTrue(paginate)
            return [dict(jobs=[copy.deepcopy(self.job)])]
        raise AssertionError(suffix)

    def evaluate(self, *args, **kwargs):
        if self.drift:
            self.drift()
        return subprocess.CompletedProcess(args, 0 if self.pass_ else 1,
                                           'Merge clearance: PASS' if self.pass_ else 'Merge clearance: BLOCKED')

    def execute(self):
        with patch.object(recovery, 'api', self.api), \
                patch.object(recovery.subprocess, 'check_output', return_value=R), \
                patch.object(recovery.subprocess, 'run', self.evaluate):
            recovery.recover('owner/repo', self.nomination)

    def test_green_publisher_and_real_clearance_rerun_actual_native_job_only(self):
        self.execute()
        self.assertEqual(self.writes, [('POST', 'actions/jobs/60/rerun')])
        self.assertEqual(self.reads.count('pulls/7'), 2)
        self.assertEqual(self.reads.count('actions/runs/50'), 2)

    def test_direct_head_source_is_supported(self):
        self.run['head_sha'] = A
        self.execute()
        self.assertEqual(len(self.writes), 1)

    def test_direct_head_requires_its_original_full_base_binding(self):
        self.run['head_sha'] = A
        self.run['pull_requests'][0]['base']['sha'] = 'e' * 40
        with self.assertRaisesRegex(ValueError, 'immutable PR/head/base'):
            self.execute()
        self.assertFalse(self.writes)

    def test_green_api_never_overrides_real_blocking_evidence(self):
        self.pass_ = False
        with self.assertRaisesRegex(ValueError, 'real clearance'):
            self.execute()
        self.assertFalse(self.writes)

    def test_recovery_refuses_changed_or_untrusted_bindings(self):
        cases = [
            lambda: self.pr['head'].update(sha=B),
            lambda: self.pr['base'].update(sha=A),
            lambda: self.pr.update(state='closed'),
            lambda: self.pr['base']['repo'].update(full_name='evil/repo'),
            lambda: self.green.update(id=31),
            lambda: self.green.update(status='in_progress'),
            lambda: self.green.update(conclusion='failure'),
            lambda: self.green['output'].update(summary='old receipt'),
            lambda: self.run.update(path='.github/workflows/other.yml'),
            lambda: self.run.update(event='push'),
            lambda: self.run['head_repository'].update(id=9),
            lambda: self.run.update(head_branch='other'),
            lambda: self.commit.update(parents=[dict(sha=A), dict(sha=B)]),
            lambda: self.job.update(check_run_url='https://api.github.com/repos/evil/repo/check-runs/40'),
            lambda: self.job.update(name='publish'),
        ]
        for i, mutate in enumerate(cases):
            with self.subTest(case=i):
                self.setUp()
                mutate()
                with self.assertRaises((ValueError, json.JSONDecodeError)):
                    self.execute()
                self.assertFalse(self.writes)

    def test_second_attempt_and_active_run_do_not_restart(self):
        for change in [dict(run_attempt=2), dict(status='in_progress')]:
            with self.subTest(change=change):
                self.setUp()
                self.run.update(change)
                self.execute()
                self.assertFalse(self.writes)

    def test_drift_after_evaluation_refuses_write(self):
        for kind in ['head', 'base', 'generation', 'attempt']:
            with self.subTest(kind=kind):
                self.setUp()
                self.drift = {'head': lambda: self.pr['head'].update(sha=B),
                              'base': lambda: self.pr['base'].update(sha=A),
                              'generation': lambda: self.green.update(id=31),
                              'attempt': lambda: self.run.update(run_attempt=2)}[kind]
                with self.assertRaises(ValueError):
                    self.execute()
                self.assertFalse(self.writes)

    def test_unreadable_evidence_never_retries_or_writes(self):
        with patch.object(recovery, 'api', side_effect=subprocess.CalledProcessError(1, ['gh'])), \
                patch.object(recovery.subprocess, 'check_output', return_value=R):
            with self.assertRaises(subprocess.CalledProcessError):
                recovery.recover('owner/repo', self.nomination)
        self.assertFalse(self.writes)


if __name__ == '__main__':
    unittest.main()
