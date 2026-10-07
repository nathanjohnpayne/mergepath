"""Hermetic CI provider, supersession and on-demand log attribution tests."""

import copy
import math
import datetime
import json
import threading
import time
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mergepath.cockpit.ci import (CIProvider, LogExcerptCache, extract_fail_lines,
                                 group_runs, normalize_check, normalize_job, supersede)
from mergepath.cockpit.github import ClientError, GitHubClient, MAX_BODY, Response, copy_json_tree
from mergepath.cockpit.inventory import Repository

REPO = 'owner/repo'
SHA = 'a' * 40
OTHER_SHA = 'b' * 40
START = '2026-10-03T00:00:00Z'
END = '2026-10-03T00:01:00Z'
LATER = '2026-10-03T00:02:00Z'
INVENTORY = (Repository('repo', REPO),)


def raw_check(check_id=100, conclusion='failure', start=START, app=1, name='lint', suite=50):
    return {'id': check_id, 'name': name, 'head_sha': SHA, 'status': 'completed',
            'conclusion': conclusion, 'started_at': start, 'completed_at': END,
            'app': {'id': app, 'slug': 'github-actions'}, 'check_suite': {'id': suite},
            'output': {}}


def raw_run(run_id=10, conclusion='failure', sha=SHA):
    return {'id': run_id, 'run_attempt': 1, 'head_sha': sha, 'name': 'repo_lint',
            'workflow_id': 9, 'check_suite_id': 50, 'pull_requests': [{'number': 7}],
            'status': 'completed', 'conclusion': conclusion, 'created_at': START,
            'run_started_at': START, 'updated_at': END}


def raw_job(job_id=20, check_id=100):
    return {'id': job_id, 'run_attempt': 1, 'name': 'lint', 'status': 'completed', 'conclusion': 'failure',
            'started_at': START, 'completed_at': END,
            'check_run_url': f'https://api.github.com/repos/{REPO}/check-runs/{check_id}',
            'steps': [{'number': 2, 'name': 'check_shell', 'status': 'completed',
                       'conclusion': 'failure', 'started_at': START, 'completed_at': END}]}


def model(checks=None, head=SHA):
    checks = checks if checks is not None else [normalize_check(REPO, raw_check(), {'50': {'workflow_id': '9', 'run_id': '10'}})]
    rows, groups = group_runs(REPO, [raw_run()], {'10': [normalize_job(raw_job())]}, supersede(checks), {'7': head})
    return {'schema': 'ci/v1', 'recent_seconds': 86400, 'runs': rows, 'groups': groups,
            'repositories': [{'repo': REPO, 'observed_at': 1000, 'attempted_at': 1000,
                              'stale': False, 'error': None, 'retry_at': None, 'history_complete': True}]}


def envelope(data=None, stale=False):
    return {'data': data or model(), 'stale': stale, 'observed_at': 1000}


def params(**updates):
    value = {'repo': REPO, 'run': '10', 'attempt': '1', 'job': '20', 'step': '2'}
    value.update(updates)
    return value


def unicode_model_and_excerpt():
    run = raw_run(); run['name'] = '🚀' * 1001
    check = raw_check(); check['output'] = {'summary': '🚀' * 4001}
    rows, groups = group_runs(REPO, [run], {'10': [normalize_job(raw_job())]},
                              [normalize_check(REPO, check, {})], {'7': SHA})
    data = model(); data.update(runs=rows, groups=groups)
    return {'data': data, 'excerpt': extract_fail_lines(('FAIL:' + '🚀' * 1000).encode(), {})}


def unmatched_checks_fixture(with_actions=True, checks=None, head=SHA, now=1000, run_prs=None, heads=None):
    run = raw_run(conclusion='success')
    if run_prs is not None:
        run['pull_requests'] = run_prs
    heads = heads if heads is not None else ({'7': head} if head is not None else {})
    job = raw_job(); job['conclusion'] = 'success'; job['steps'][0]['conclusion'] = 'success'
    external = raw_check(200, app=77, name='external gate')
    external['app']['slug'] = 'external-app'
    external['output'] = {'summary': 'External gate failed; check-run diagnostic'}
    checks = checks if checks is not None else ([raw_check(conclusion='success')] if with_actions else []) + [external]
    calls = []
    class Client:
        def pages(self, route, **kwargs):
            calls.append({'route': route, **kwargs})
            if '/pulls?' in route: return [{'number': number, 'head': {'sha': sha}} for number, sha in heads.items()]
            if '/actions/runs?' in route: return [run] if with_actions and 'created=' in route else []
            if '/jobs?' in route: return [job]
            if '/check-runs?' in route: return [check for check in checks if '/commits/' + check['head_sha'] + '/' in route]
            raise AssertionError('unexpected route: ' + route)
    provider = CIProvider(Client(), INVENTORY, clock=lambda: now, monotonic=lambda: 0)
    sample = provider(5)
    return {'data': sample.data, 'calls': calls, 'hot': sample.hot}


def coverage_fixture(kind):
    heads = {'7': SHA}
    runs, jobs, checks = [raw_run(conclusion='success')], {'10': [raw_job()]}, [raw_check(conclusion='success')]
    jobs['10'][0]['conclusion'] = jobs['10'][0]['steps'][0]['conclusion'] = 'success'
    if kind in ('uncovered', 'uncovered-only'):
        heads['8'] = OTHER_SHA
        if kind == 'uncovered-only':
            runs, jobs, checks = [], {}, []
    else:
        conclusion = {'all-pass': 'success', 'neutral': 'neutral', 'skipped': 'skipped', 'check-neutral': 'neutral',
                      'check-skipped': 'skipped', 'stale': 'stale', 'check-stale': 'stale',
                      'unknown-completion': None, 'check-unknown-completion': None, 'unknown-status': 'success'}.get(kind, 'cancelled')
        sha = OTHER_SHA if kind == 'old-cancelled' else SHA
        run = raw_run(11, conclusion, sha); run['check_suite_id'] = 51
        job = raw_job(21, 101); job['conclusion'] = job['steps'][0]['conclusion'] = conclusion
        check = raw_check(101, conclusion, suite=51); check['head_sha'] = sha
        if kind.startswith('check-'):
            check['app'] = {'id': 77, 'slug': 'external-app'}
        else:
            runs.append(run); jobs['11'] = [job]
        if kind == 'unknown-status':
            run['status'] = 'unknown'
        checks.append(check)
        if kind == 'running-cancelled':
            runs[0].update(status='in_progress', conclusion=None)
        if kind == 'failed-cancelled':
            runs[0]['conclusion'] = jobs['10'][0]['conclusion'] = checks[0]['conclusion'] = 'failure'
    calls = []
    class Client:
        def pages(self, route, **kwargs):
            calls.append({'route': route, **kwargs})
            if '/pulls?' in route: return [{'number': number, 'head': {'sha': sha}} for number, sha in heads.items()]
            if '/actions/runs?' in route: return runs if 'created=' in route else []
            if '/jobs?' in route: return jobs[route.split('/runs/')[1].split('/')[0]]
            if '/check-runs?' in route: return [check for check in checks if '/commits/' + check['head_sha'] + '/' in route]
            raise AssertionError('unexpected route: ' + route)
    sample = CIProvider(Client(), INVENTORY, clock=lambda: 1000, monotonic=lambda: 0)(5)
    return {'data': sample.data, 'calls': calls, 'hot': sample.hot}


def browser_fixtures():
    fixtures = {'model': model(), 'unicode': unicode_model_and_excerpt(),
                'workflow-no-pr': unmatched_checks_fixture(checks=[raw_check()], run_prs=[]),
                'no-head': unmatched_checks_fixture(head=None)}
    for with_actions in (True, False):
        fixtures[f'external:{with_actions}'] = unmatched_checks_fixture(with_actions)
        for status in ('queued', 'in_progress'):
            checks = [raw_check(conclusion='success')] if with_actions else []
            for check_id, conclusion, name in ((200, 'failure', 'external gate'),
                                                (201, 'success', 'external gate'),
                                                (202, None, 'independent check')):
                check = raw_check(check_id, conclusion, START if check_id == 200 else LATER, app=77, name=name)
                check['app']['slug'] = 'external-app'
                if check_id == 202:
                    check.update(status=status, completed_at=None)
                checks.append(check)
            fixtures[f'mixed:{with_actions}:{status}'] = unmatched_checks_fixture(with_actions, checks=checks)
    for app in (None, {'id': 1, 'slug': 'github-actions'}):
        external = raw_check(201, 'success', LATER, app=77)
        external['app']['slug'] = 'external-app'
        checks = [raw_check(conclusion='success'), {**raw_check(200, suite=999), 'app': app}, external]
        fixtures[f'unknown:{app is None}'] = unmatched_checks_fixture(checks=checks)
    for status in ('queued', 'in_progress', 'completed', 'unknown'):
        fixtures[f'pending:{status}'] = unmatched_checks_fixture(checks=[raw_check(conclusion='success'),
            {**raw_check(200), 'status': status, 'conclusion': None}])
    for key, head, run_prs in (('current', SHA, None), ('old', OTHER_SHA, None),
                               ('closed', None, None), ('unattached', None, [])):
        fixtures[f'passed:{key}'] = unmatched_checks_fixture(checks=[raw_check(conclusion='success')],
                                                            head=head, run_prs=run_prs)
    for kind in ('uncovered', 'uncovered-only', 'cancelled', 'old-cancelled', 'all-pass', 'neutral', 'skipped', 'stale', 'unknown-completion',
                 'check-neutral', 'check-skipped', 'check-stale', 'check-unknown-completion', 'unknown-status',
                 'check-cancelled', 'running-cancelled', 'failed-cancelled'):
        fixtures[f'coverage:{kind}'] = coverage_fixture(kind)
    return fixtures


class SupersessionTests(unittest.TestCase):
    def test_unicode_producer_limits_preserve_complete_code_points(self):
        fixture = unicode_model_and_excerpt()
        self.assertEqual(fixture['data']['runs'][0]['name'], '🚀' * 1000)
        self.assertEqual(fixture['data']['runs'][0]['diagnostics'][0]['text'], '🚀' * 4000)
        self.assertEqual(fixture['excerpt']['lines'], ['FAIL:' + '🚀' * 995])
        self.assertTrue(fixture['excerpt']['truncated'])

    def test_same_sha_producer_and_check_later_pass_supersedes(self):
        checks = [normalize_check(REPO, raw_check(), {'50': {'workflow_id': '9', 'run_id': '10'}}),
                  normalize_check(REPO, raw_check(101, 'success', LATER), {'50': {'workflow_id': '9', 'run_id': '10'}})]
        row = model(checks)['runs'][0]
        self.assertTrue(row['superseded'])
        self.assertFalse(row['actionable'])
        self.assertEqual(row['checks'][0]['superseded_by'], '101')

    def test_one_success_supersedes_at_most_one_same_name_failure(self):
        # #1815: with full check history, two failed same-name checks and one later success must
        # leave one failure unsuperseded and the row actionable; a second success clears both.
        def ext(check_id, conclusion, start):
            check = raw_check(check_id, conclusion, start, app=77, name='external gate'); check['app']['slug'] = 'external-app'
            return check
        first, second = ext(200, 'failure', START), ext(202, 'failure', END)
        for successes, cleared in (([ext(201, 'success', LATER)], 1), ([ext(201, 'success', LATER), ext(203, 'success', '2026-10-03T00:03:00Z')], 2)):
            with self.subTest(successes=len(successes)):
                observed = supersede([normalize_check(REPO, c, {}) for c in (first, second, *successes)])
                links = [c['superseded_by'] for c in observed if c['conclusion'] == 'failure']
                self.assertEqual(sum(link is not None for link in links), cleared)
                self.assertEqual(len({link for link in links if link}), cleared, 'a success is never reused')
                row = unmatched_checks_fixture(False, [first, second, *successes])['data']['check_rows'][0]
                self.assertEqual(row['superseded'], cleared == 2); self.assertEqual(row['actionable'], cleared < 2)
        # The latest failure takes the earliest later success, so an earlier failure keeps a later one.
        early, late = ext(200, 'failure', START), ext(202, 'failure', '2026-10-03T00:02:30Z')
        observed = supersede([normalize_check(REPO, c, {}) for c in (early, late, ext(201, 'success', LATER), ext(203, 'success', '2026-10-03T00:03:00Z'))])
        self.assertEqual([c['superseded_by'] for c in observed[:2]], ['201', '203'])

    def test_failed_job_without_an_observed_check_keeps_the_run_unknown_beside_a_superseded_sibling(self):
        # #1815: one failed job's check is superseded by a later success; another failed job has no
        # parseable check-run identity. The run must stay unknown, never superseded.
        lineage = {'50': {'workflow_id': '9', 'run_id': '10'}}
        checks = supersede([normalize_check(REPO, raw_check(), lineage), normalize_check(REPO, raw_check(101, 'success', LATER), lineage)])
        orphan = {**raw_job(21, 999), 'name': 'build', 'check_run_url': None}
        for jobs, unknown in (([raw_job()], False), ([raw_job(), orphan], True), ([raw_job(), raw_job(21, 102)], True)):
            with self.subTest(jobs=len(jobs), orphan=unknown):
                rows, _ = group_runs(REPO, [raw_run()], {'10': [normalize_job(job) for job in jobs]}, copy.deepcopy(checks), {'7': SHA})
                self.assertEqual(rows[0]['check_evidence_unknown'], unknown)
                self.assertEqual(rows[0]['superseded'], not unknown)
                self.assertFalse(rows[0]['actionable'])

    def test_no_later_pass_keeps_actionable_failure(self):
        row = model()['runs'][0]
        self.assertTrue(row['actionable'])
        self.assertEqual(row['severity'], 'bump')
        self.assertEqual(row['rerun_command'], 'gh run rerun 10 --failed --repo owner/repo')

    def test_other_app_workflow_check_sha_or_repo_never_supersedes(self):
        failed = normalize_check(REPO, raw_check(), {'50': {'workflow_id': '9', 'run_id': '10'}})
        passed = normalize_check(REPO, raw_check(101, 'success', LATER), {'50': {'workflow_id': '9', 'run_id': '10'}})
        for field, value in [('producer', 'app:2:workflow:9'), ('producer', 'app:1:workflow:10'),
                             ('name', 'other'), ('sha', OTHER_SHA), ('repo', 'owner/other')]:
            other = {**passed, field: value}
            self.assertIsNone(supersede([copy.deepcopy(failed), other])[0]['superseded_by'])

    def test_unknown_producer_time_and_earlier_success_do_not_clear(self):
        failed = normalize_check(REPO, raw_check(), {'50': {'workflow_id': '9', 'run_id': '10'}})
        for producer, start in [(None, LATER), ('app:1:workflow:9', START), ('app:1:workflow:9', None)]:
            passed = normalize_check(REPO, raw_check(101, 'success', start), {'50': {'workflow_id': '9', 'run_id': '10'}})
            passed['producer'] = producer
            self.assertIsNone(supersede([copy.deepcopy(failed), passed])[0]['superseded_by'])

    def test_missing_actions_run_lineage_preserves_failure(self):
        failed = normalize_check(REPO, raw_check(), {'50': {'workflow_id': '9', 'run_id': '10'}})
        for mapping in ({}, {'50': '9'}, {'50': None}, {'50': {'workflow_id': '9', 'run_id': None}}):
            passed = normalize_check(REPO, raw_check(101, 'success', LATER), mapping)
            self.assertIsNone(supersede([copy.deepcopy(failed), passed])[0]['superseded_by'])
            self.assertTrue(model([copy.deepcopy(failed), passed])['runs'][0]['actionable'])

    def test_changed_head_and_missing_head_keep_history(self):
        old = model(head=OTHER_SHA)['runs'][0]
        self.assertFalse(old['current_head'])
        self.assertFalse(old['actionable'])
        rows, _ = group_runs(REPO, [raw_run()], {'10': [normalize_job(raw_job())]}, [], {})
        self.assertIsNone(rows[0]['current_head'])
        self.assertTrue(rows[0]['check_evidence_unknown'])

    def test_diagnostic_special_states_require_specific_observation(self):
        for diagnostic, severity in [('CodeQL finalize exited 32', 'bump'),
                                      ('CodeQL analysis failed: not retryable', 'boulder'),
                                      ('API rate limit exceeded for installation ID 5', 'boulder')]:
            raw = raw_check(); raw['output'] = {'summary': diagnostic}
            row = model([normalize_check(REPO, raw, {'50': {'workflow_id': '9', 'run_id': '10'}})])['runs'][0]
            self.assertEqual(row['severity'], severity)
            self.assertNotIn('remaining', row)

    def test_exact_large_ids_emit_strings_through_json(self):
        huge = 900719925474099312345
        raw = raw_run(huge)
        raw['pull_requests'] = [{'number': huge + 1}]
        raw['workflow_id'] = huge + 2
        rows, groups = group_runs(REPO, [raw], {str(huge): []}, [], {str(huge + 1): SHA})
        data = copy_json_tree({'runs': rows, 'groups': groups})
        encoded = json.loads(json.dumps(data))
        self.assertEqual(encoded['runs'][0]['id'], str(huge))
        self.assertEqual(encoded['runs'][0]['pr'], str(huge + 1))


class ProviderTests(unittest.TestCase):
    def test_open_head_without_workflows_or_checks_retains_explicit_unknown_coverage(self):
        for kind, expected_prs in (('uncovered', ['8']), ('uncovered-only', ['7', '8'])):
            with self.subTest(kind=kind):
                fixture = coverage_fixture(kind); data = fixture['data']
                self.assertEqual([row['pr'] for row in data['check_rows']], expected_prs)
                for row in data['check_rows']:
                    self.assertTrue(row['current_head']); self.assertTrue(row['check_evidence_unknown'])
                    self.assertEqual(row['status'], 'unknown'); self.assertIsNone(row['conclusion'])
                    self.assertEqual(row['checks'], []); self.assertEqual(row['jobs'], [])
                    self.assertFalse(row['actionable']); self.assertFalse(row['superseded'])
                    for key in ('id', 'attempt', 'workflow_id', 'rerun_command', 'created_at', 'started_at', 'updated_at'):
                        self.assertIsNone(row[key])
                    self.assertEqual(row['jobs_scope'], 'none')
                    self.assertIn('No workflow or check runs observed', row['reason'])
                    group = next(group for group in data['groups'] if group['pr'] == row['pr'])
                    self.assertEqual(group['run_keys'], [])
                    self.assertEqual(group['check_keys'], [row['key']])
                self.assertEqual(sum('/jobs?' in call['route'] for call in fixture['calls']), int(kind == 'uncovered'))
                self.assertEqual(sum('/check-runs?' in call['route'] for call in fixture['calls']), 2)

    def test_workflow_without_pr_metadata_binds_every_matching_observed_head(self):
        fixture = unmatched_checks_fixture(checks=[raw_check()], run_prs=[],
                                           heads={'7': SHA, '8': SHA, '9': OTHER_SHA})
        data = fixture['data']
        self.assertEqual([row['pr'] for row in data['runs']], ['7', '8'])
        self.assertTrue(all(row['current_head'] and row['actionable'] for row in data['runs']))
        self.assertEqual([row['key'] for row in data['runs']], [REPO + ':10:7', REPO + ':10:8'])
        self.assertEqual([group['pr'] for group in data['groups'] if group['run_keys']], ['7', '8'])
        self.assertEqual([row for row in data['check_rows'] if row['checks']], [])
        self.assertEqual([row['pr'] for row in data['check_rows']], ['9'])
        marker = data['check_rows'][0]
        self.assertEqual(marker['sha'], OTHER_SHA)
        self.assertTrue(marker['current_head'] and marker['check_evidence_unknown'])
        marker_group = next(group for group in data['groups'] if group['pr'] == '9')
        self.assertEqual(marker_group['run_keys'], [])
        self.assertEqual(marker_group['check_keys'], [marker['key']])
        self.assertEqual(sum('/jobs?' in call['route'] for call in fixture['calls']), 1)
        self.assertEqual({row['id'] for row in data['runs']}, {'10'})

    def test_workflow_preserves_old_metadata_owner_and_adds_matching_open_head(self):
        data = unmatched_checks_fixture(checks=[raw_check()], heads={'7': OTHER_SHA, '8': SHA})['data']
        self.assertEqual([(row['pr'], row['current_head'], row['actionable']) for row in data['runs']],
                         [('7', False, False), ('8', True, True)])

    def test_workflow_without_metadata_or_matching_head_keeps_unknown_owner(self):
        for heads in ({}, {'7': OTHER_SHA}):
            with self.subTest(heads=heads):
                row = unmatched_checks_fixture(checks=[raw_check()], run_prs=[], heads=heads)['data']['runs'][0]
                self.assertIsNone(row['pr']); self.assertIsNone(row['current_head'])
                self.assertFalse(row['actionable'])

    def test_provider_retains_external_failure_on_current_head_with_or_without_actions(self):
        for with_actions in (True, False):
            with self.subTest(with_actions=with_actions):
                fixture = unmatched_checks_fixture(with_actions)
                data = fixture['data']
                self.assertFalse(data['repositories'][0]['stale'])
                external_rows = [row for row in data.get('check_rows', []) if any(check['id'] == '200' for check in row['checks'])]
                self.assertEqual(len(external_rows), 1)
                row = external_rows[0]
                self.assertEqual(row['pr'], '7'); self.assertEqual(row['sha'], SHA)
                self.assertTrue(row['current_head']); self.assertTrue(row['actionable'])
                self.assertEqual(row['checks'][0]['producer'], 'app:77')
                self.assertEqual(row['diagnostics'][0]['source'], 'check-run output')
                self.assertIsNone(row['rerun_command'])
                self.assertEqual(sum('/jobs?' in call['route'] for call in fixture['calls']), int(with_actions))
                self.assertEqual(sum('/check-runs?' in call['route'] for call in fixture['calls']), 1)
                self.assertTrue(all(call['deadline'] == 4.75 for call in fixture['calls']))

    def test_unmatched_unknown_producer_and_actions_lineage_cannot_be_cleared_by_peer(self):
        for app in (None, {'id': 1, 'slug': 'github-actions'}):
            with self.subTest(app=app):
                failed = raw_check(200, app=77, suite=999); failed['app'] = app
                passed = raw_check(201, 'success', LATER, app=77); passed['app']['slug'] = 'external-app'
                data = unmatched_checks_fixture(checks=[raw_check(conclusion='success'), failed, passed])['data']
                row = data['check_rows'][0]
                self.assertTrue(row['actionable']); self.assertFalse(row['superseded'])
                self.assertIsNone(row['checks'][0]['producer'])
                self.assertIsNone(row['checks'][0]['superseded_by'])
                self.assertEqual([check['id'] for check in data['runs'][0]['checks']], ['100'])

    def test_unmatched_other_app_supersession_requires_same_app_name_and_order(self):
        failed = raw_check(200, app=77); failed['app']['slug'] = 'external-app'
        passed = raw_check(201, 'success', LATER, app=77); passed['app']['slug'] = 'external-app'
        for mutation, superseded in [({}, True), ({'app': {'id': 78, 'slug': 'external-app'}}, False),
                                     ({'name': 'other check'}, False), ({'started_at': START}, False),
                                     ({'started_at': None}, False)]:
            with self.subTest(mutation=mutation):
                data = unmatched_checks_fixture(False, [failed, {**passed, **mutation}])['data']
                row = data['check_rows'][0]
                self.assertEqual(row['superseded'], superseded)
                self.assertEqual(row['actionable'], not superseded)
                self.assertEqual(row['checks'][0]['superseded_by'], '201' if superseded else None)
                self.assertEqual(row['checks'][0]['started_at'], normalize_check(REPO, failed, {})['started_at'])

    def test_successful_history_off_open_heads_keeps_workflow_result_without_detail_reads(self):
        # A completed success on a SHA that is no open HEAD is history: its workflow result
        # stays, but no job or check pages are read for it (fleet volume, #1810).
        for head, current in [(OTHER_SHA, False), (None, None)]:
            with self.subTest(head=head):
                fixture = unmatched_checks_fixture(head=head); data = fixture['data']
                run = data['runs'][0]
                self.assertEqual((run['pr'], run['sha'], run['current_head']), ('7', SHA, current))
                self.assertEqual(run['jobs_scope'], 'not-fetched'); self.assertEqual(run['jobs'], []); self.assertEqual(run['checks'], [])
                self.assertFalse(run['actionable']); self.assertFalse(run['superseded']); self.assertEqual(run['conclusion'], 'success')
                self.assertEqual(sum('/jobs?' in call['route'] for call in fixture['calls']), 0)
                self.assertEqual([call['route'] for call in fixture['calls'] if '/check-runs?' in call['route']],
                                 [f'/repos/{REPO}/commits/{OTHER_SHA}/check-runs?filter=all&per_page=100'] if head else [])
                self.assertEqual([row['sha'] for row in data['check_rows']], [OTHER_SHA] if head else [])
                self.assertEqual(data['groups'][0]['run_keys'], [run['key']])
                self.assertFalse(fixture['hot'])

    def test_absent_failed_check_runs_stay_unknown_and_are_never_read_as_superseded(self):
        # A failed job's check-run can be absent from what was read. Absence is never clearance:
        # the run keeps check_evidence_unknown whatever same-name successes sit on the SHA.
        peer = raw_run(11, 'success'); peer['check_suite_id'] = 51
        for label, present in (('same-run later success of the same name', [raw_check(101, 'success', LATER, name='lint', suite=50)]),
                               ('another run of the same workflow', [raw_check(101, 'success', LATER, name='lint', suite=51)]),
                               ('nothing on the SHA', [])):
            with self.subTest(case=label):
                class Client:
                    def pages(self, route, **kwargs):
                        if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                        if '/actions/runs?' in route: return [raw_run(), peer] if 'created=' in route else []
                        if '/jobs?' in route: return [raw_job()] if '/runs/10/' in route else [{**raw_job(21, 102), 'conclusion': 'success'}]
                        if '/check-runs?' in route:
                            assert 'filter=all' in route, route; return list(present)
                        raise AssertionError('unexpected route: ' + route)
                row = next(r for r in CIProvider(Client(), INVENTORY, clock=lambda: 1000, monotonic=lambda: 0)(5).data['runs'] if r['id'] == '10')
                self.assertTrue(row['check_evidence_unknown']); self.assertFalse(row['superseded']); self.assertFalse(row['actionable'])
                self.assertEqual(row['checks'], []); self.assertEqual(row['jobs_scope'], 'all-attempts'); self.assertIsNone(row['severity'])

    def test_open_head_reads_every_check_run_so_a_later_completing_success_cannot_hide_a_failure(self):
        # #1815 Phase 4b: the latest filter keeps one run per name by completion time. An external
        # success that completed later but did not start later must not hide the failure.
        failed = raw_check(200, 'failure', LATER, app=77, name='external gate'); failed['app']['slug'] = 'external-app'
        for start, superseded in (('2026-10-03T00:01:30Z', False), (None, False), ('2026-10-03T00:03:00Z', True)):
            with self.subTest(success_start=start):
                passed = {**raw_check(201, 'success', start, app=77, name='external gate'), 'completed_at': '2026-10-03T00:04:00Z'}
                passed['app'] = {'id': 77, 'slug': 'external-app'}
                routes = []
                class Client:
                    def pages(self, route, **kwargs):
                        routes.append(route)
                        if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                        if '/actions/runs?' in route: return []
                        if '/check-runs?' in route:
                            # GitHub's latest filter would return only the later-completing success.
                            return [passed] if 'filter=latest' in route else [failed, passed]
                        raise AssertionError('unexpected route: ' + route)
                row = CIProvider(Client(), INVENTORY, clock=lambda: 1000, monotonic=lambda: 0)(5).data['check_rows'][0]
                self.assertEqual([r for r in routes if '/check-runs?' in r], [f'/repos/{REPO}/commits/{SHA}/check-runs?filter=all&per_page=100'])
                self.assertEqual(row['superseded'], superseded); self.assertEqual(row['actionable'], not superseded)
                self.assertEqual(row['severity'], None if superseded else 'bump')

    def test_failed_run_off_open_heads_keeps_suite_diagnostics_for_the_installation_window(self):
        # #1815 Phase 4b: the Actions budget reads installation exhaustion from failed runs' check
        # diagnostics in the last hour, including scheduled and default-branch runs off every open HEAD.
        from mergepath.cockpit.actions import ActionsProvider, ci_observation
        now = [1791300000.0]
        def iso(value): return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        recent = raw_run(31, 'failure', OTHER_SHA); recent.update(created_at=iso(now[0] - 600), pull_requests=[], check_suite_id=61)
        old = raw_run(32, 'failure', OTHER_SHA); old.update(created_at=iso(now[0] - 3700), pull_requests=[], check_suite_id=62)
        passed = raw_run(33, 'success', OTHER_SHA); passed.update(created_at=iso(now[0] - 600), pull_requests=[], check_suite_id=63)
        exhausted = raw_check(131, 'failure', suite=61); exhausted['head_sha'] = OTHER_SHA
        exhausted['output'] = {'title': 'lint failed', 'summary': 'API rate limit exceeded for installation ID 7'}
        routes = []
        class Client:
            def pages(self, route, **kwargs):
                routes.append(route)
                if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                if '/actions/runs?' in route: return [recent, old, passed] if 'created=' in route else []
                if '/jobs?' in route:
                    run_id = route.split('/runs/')[1].split('/')[0]
                    return [raw_job(int(run_id) * 10, 131 if run_id == '31' else 132)]
                if '/commits/' in route and '/check-runs?' in route: return []
                if '/check-suites/61/check-runs?filter=all&per_page=100' in route: return [exhausted]
                raise AssertionError('unexpected route: ' + route)
        provider = CIProvider(Client(), INVENTORY, clock=lambda: now[0], monotonic=lambda: 0)
        data = provider(5).data; rows = {row['id']: row for row in data['runs']}
        self.assertEqual([r for r in routes if '/check-suites/' in r], [f'/repos/{REPO}/check-suites/61/check-runs?filter=all&per_page=100'])
        self.assertEqual([c['id'] for c in rows['31']['checks']], ['131']); self.assertFalse(rows['31']['check_evidence_unknown'])
        self.assertFalse(rows['31']['actionable']); self.assertIsNone(rows['31']['current_head'])
        self.assertTrue(rows['32']['check_evidence_unknown']); self.assertEqual(rows['32']['checks'], [])
        envelope = {'stale': False, 'data': data}
        observed = ci_observation(envelope, REPO, now[0])
        self.assertEqual([(r['id'], r['failure_message']) for r in observed['hour'] if r['failure_message']], [(31, 'api rate limit exceeded for installation')])
        budget = ActionsProvider(None, INVENTORY, clock=lambda: now[0], monotonic=lambda: 0,
                                 ci_snapshot=lambda repo, at: ci_observation(envelope, repo, at)).fetch(30).data['repositories'][0]
        self.assertEqual(budget['installation_runs'], ['31'])
        # A completed attempt's suite is final: the next scan reuses it, a new attempt reads again.
        routes.clear(); provider(5)
        self.assertEqual([r for r in routes if '/check-suites/' in r], [])
        recent['run_attempt'] = 2; routes.clear(); provider(5)
        self.assertEqual([r for r in routes if '/check-suites/' in r], [f'/repos/{REPO}/check-suites/61/check-runs?filter=all&per_page=100'])

    def test_page_shift_repeats_are_deduplicated_instead_of_failing_the_repository(self):
        duplicate = raw_check(); duplicate['output'] = {'summary': 'second copy'}
        class Client:
            def pages(self, route, **kwargs):
                if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                if '/actions/runs?' in route: return [raw_run(), raw_run()] if 'created=' in route else []
                if '/jobs?' in route: return [raw_job()]
                return [raw_check(), duplicate]
        data = CIProvider(Client(), INVENTORY, clock=lambda: 1000, monotonic=lambda: 0)(5).data
        self.assertFalse(data['repositories'][0]['stale']); self.assertEqual(len(data['runs']), 1)
        self.assertEqual([check['id'] for check in data['runs'][0]['checks']], ['100'])
        self.assertEqual(data['runs'][0]['diagnostics'], [])

    def test_detail_scope_floored_cutoff_and_hot_follow_open_heads_not_sweeps(self):
        live = raw_run(12, None, OTHER_SHA); live.update(status='in_progress', conclusion=None, pull_requests=[])
        failed = raw_run(13, 'timed_out', OTHER_SHA); failed['pull_requests'] = []
        cancelled = raw_run(14, 'cancelled', OTHER_SHA); cancelled['pull_requests'] = []
        on_head = raw_run(15, 'success', SHA)
        calls, now = [], [1791300000.0]  # 2026-10-06T15:20:00Z
        class Client:
            def pages(self, route, **kwargs):
                calls.append(route)
                if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                if '/actions/runs?' in route: return [live, failed, cancelled, on_head] if 'created=' in route else []
                if '/jobs?' in route: return [{**raw_job(int(route.split('/runs/')[1].split('/')[0]) * 10, 100), 'conclusion': 'success'}]
                if '/check-runs?' in route: return []
                raise AssertionError('unexpected route: ' + route)
        provider = CIProvider(Client(), INVENTORY, clock=lambda: now[0], monotonic=lambda: 0)
        sample = provider(5); rows = {row['id']: row for row in sample.data['runs']}
        self.assertEqual({rid: row['jobs_scope'] for rid, row in rows.items()},
                         {'12': 'all-attempts', '13': 'all-attempts', '14': 'not-fetched', '15': 'all-attempts'})
        self.assertEqual(rows['14']['jobs'], []); self.assertEqual(len(rows['15']['jobs']), 1)
        self.assertEqual(sorted(route.split('/runs/')[1].split('/')[0] for route in calls if '/jobs?' in route), ['12', '13', '15'])
        self.assertEqual([route.split('/commits/')[1].split('/')[0] for route in calls if '/check-runs?' in route], [SHA], 'check-runs are read for open HEADs only')
        self.assertEqual(sample.data['recent_seconds'], 10800)
        self.assertIn('created=%3E%3D2026-10-06T12%3A00%3A00Z', next(route for route in calls if 'created=' in route))
        self.assertFalse(sample.hot, 'a live sweep off every open HEAD keeps the idle cadence')
        live['head_sha'] = SHA; now[0] += 20
        self.assertTrue(provider(5).hot)
        with self.assertRaises(ValueError):
            CIProvider(Client(), INVENTORY, jobs_cache=0)

    def test_window_beyond_the_page_bound_lists_verdict_runs_completely_and_says_history_is_unlisted(self):
        # #1817: nathanpaynedotcom held 1,452 runs in three hours, almost all workflow_run relay
        # successes off the open heads, and GitHub lists at most 1,000 runs for a filtered query.
        from mergepath.cockpit.actions import ci_observation
        live = raw_run(12, None, OTHER_SHA); live.update(status='queued', conclusion=None, pull_requests=[])
        failed = raw_run(13, 'failure', OTHER_SHA); failed['pull_requests'] = []
        relay = raw_run(14, 'success', OTHER_SHA); relay['pull_requests'] = []
        on_head = raw_run(15, 'success', SHA)
        window = 'created=%3E%3D2026-10-06T12%3A00%3A00Z'
        calls, state = [], {'window': 'page_limit', 'targeted': None}
        class Client:
            def pages(self, route, **kwargs):
                calls.append(route)
                if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                if '/actions/runs?' in route:
                    query = route.split('/actions/runs?per_page=100&')[1]
                    if query == window:
                        if state['window'] != 'complete': raise ClientError(state['window'])
                        return [live, failed, relay, on_head]
                    if state['targeted'] == query: raise ClientError('page_limit')
                    return {window + '&status=failure': [failed], window + '&head_sha=' + SHA: [on_head],
                            'status=queued': [live]}.get(query, [])
                if '/jobs?' in route: return [{**raw_job(int(route.split('/runs/')[1].split('/')[0]) * 10, 100), 'conclusion': 'success'}]
                if '/check-runs?' in route: return []
                raise AssertionError('unexpected route: ' + route)
        provider = CIProvider(Client(), INVENTORY, clock=lambda: 1791300000.0, monotonic=lambda: 0)
        data = provider(5).data
        runs = [route.split('/actions/runs?per_page=100&')[1] for route in calls if '/actions/runs?' in route]
        self.assertEqual(runs, [window] + [window + '&status=' + status for status in
                                           ('action_required', 'failure', 'startup_failure', 'timed_out')]
                         + [window + '&head_sha=' + SHA] + ['status=' + status for status in
                                                            ('in_progress', 'pending', 'queued', 'requested', 'waiting')])
        # Live, failed and open-HEAD runs stay complete and fresh; the relay success off the heads is not listed.
        self.assertEqual(sorted(row['id'] for row in data['runs']), ['12', '13', '15'])
        self.assertEqual({key: data['repositories'][0][key] for key in ('stale', 'error', 'history_complete')},
                         {'stale': False, 'error': None, 'history_complete': False})
        self.assertTrue(next(row for row in data['runs'] if row['id'] == '13')['check_evidence_unknown'])
        # The hour's volume needs every run, so the Actions budget refuses this repository.
        self.assertIsNone(ci_observation({'stale': False, 'data': data}, REPO, data['repositories'][0]['observed_at']))
        # A verdict query that cannot be listed completely leaves the repository stale, never partial.
        for query in (window + '&status=timed_out', window + '&head_sha=' + SHA):
            with self.subTest(query=query):
                state['targeted'] = query
                fresh = CIProvider(Client(), INVENTORY, clock=lambda: 1791300000.0, monotonic=lambda: 0)(5).data
                self.assertEqual((fresh['runs'], fresh['repositories'][0]['error']), ([], 'page_limit'))
                self.assertIsNone(fresh['repositories'][0]['observed_at'])
        # A window that fits keeps listing it whole, with no extra queries.
        state.update(window='complete', targeted=None); calls.clear()
        data = CIProvider(Client(), INVENTORY, clock=lambda: 1791300000.0, monotonic=lambda: 0)(5).data
        self.assertEqual(sorted(row['id'] for row in data['runs']), ['12', '13', '14', '15'])
        self.assertTrue(data['repositories'][0]['history_complete'])
        self.assertFalse(any('&status=failure' in route or '&head_sha=' in route for route in calls))
        self.assertIsNotNone(ci_observation({'stale': False, 'data': data}, REPO, data['repositories'][0]['observed_at']))
        # Any other window failure still fails the repository.
        state['window'] = 'invalid_next_link'
        data = CIProvider(Client(), INVENTORY, clock=lambda: 1791300000.0, monotonic=lambda: 0)(5).data
        self.assertEqual((data['runs'], data['repositories'][0]['error']), ([], 'invalid_next_link'))

    def test_unmatched_live_and_unknown_checks_do_not_invent_completed_success(self):
        for status, conclusion, hot, unknown in [('queued', None, True, False), ('in_progress', None, True, False),
                                                ('completed', None, False, True), ('unknown', None, False, True)]:
            with self.subTest(status=status):
                check = raw_check(200); check.update(status=status, conclusion=conclusion)
                fixture = unmatched_checks_fixture(False, [check]); data = fixture['data']
                self.assertEqual(fixture['hot'], hot)
                row = data['check_rows'][0]
                self.assertEqual(row['status'], status); self.assertIsNone(row['conclusion'])
                self.assertEqual(row['check_evidence_unknown'], unknown)
                self.assertIsNone(row['id']); self.assertIsNone(row['attempt']); self.assertIsNone(row['workflow_id'])
                self.assertEqual(row['jobs'], []); self.assertEqual(data['runs'], [])
                self.assertTrue(all(row[field] is None for field in ('created_at', 'started_at', 'updated_at')))

    def test_unmatched_checks_refresh_while_completed_jobs_cache_and_deny_retains_age(self):
        now, calls = [1000], []
        failed = raw_check(200, app=77); failed['app']['slug'] = 'external-app'
        passed = raw_check(201, 'success', LATER, app=77); passed['app']['slug'] = 'external-app'
        class Client:
            denied = False
            checks = [raw_check(conclusion='success'), failed]
            def pages(self, route, **kwargs):
                calls.append(route)
                if self.denied: raise ClientError('permission_denied')
                if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                if '/actions/runs?' in route: return [raw_run(conclusion='success')] if 'created=' in route else []
                if '/jobs?' in route: return [raw_job()]
                return self.checks
        client = Client(); provider = CIProvider(client, INVENTORY, clock=lambda: now[0])
        first = provider(time.monotonic()+5).data
        client.checks.append(passed); now[0] += 20
        second = provider(time.monotonic()+5).data
        self.assertTrue(first['check_rows'][0]['actionable']); self.assertFalse(second['check_rows'][0]['actionable'])
        self.assertEqual(sum('/jobs?' in route for route in calls), 1)
        self.assertEqual(sum('/check-runs?' in route for route in calls), 2)
        client.denied = True; now[0] += 20
        third = provider(time.monotonic()+5).data
        self.assertTrue(third['repositories'][0]['stale'])
        self.assertEqual(third['repositories'][0]['observed_at'], 1020)
        self.assertEqual(third['check_rows'], second['check_rows'])

    def test_provider_accepts_check_url_repository_casing_and_keeps_enrolled_identity(self):
        job = raw_job(); job['check_run_url'] = job['check_run_url'].replace(REPO, 'OwNeR/RePo')
        class Client:
            def pages(self, route, **kwargs):
                if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                if '/actions/runs?' in route: return [raw_run()] if 'created=' in route else []
                if '/jobs?' in route: return [job]
                return [raw_check()]
        data = CIProvider(Client(), INVENTORY)(time.monotonic() + 5).data
        self.assertFalse(data['repositories'][0]['stale'])
        self.assertEqual(data['runs'][0]['repo'], REPO)
        self.assertEqual(data['runs'][0]['jobs'][0]['check_id'], '100')
        self.assertTrue(data['runs'][0]['actionable'])

    def test_check_url_casing_does_not_relax_authority_path_or_identity(self):
        base = raw_job()['check_run_url']
        for url in [base.replace(REPO, 'other/repo'), base.replace(REPO, 'owner/other'),
                    base.replace(REPO, 'owner/repo-extra'), base.replace(REPO, 'owner/repo%2Fextra')]:
            with self.subTest(url=url), self.assertRaisesRegex(ClientError, 'invalid_upstream_json'):
                normalize_job({**raw_job(), 'check_run_url': url}, REPO)
        for observed, enrolled in [('owner/Straße', 'owner/strasse'), ('owner/K', 'owner/k'),
                                   ('owner/ſ', 'owner/s')]:
            with self.subTest(observed=observed), self.assertRaisesRegex(ClientError, 'invalid_upstream_json'):
                normalize_job({**raw_job(), 'check_run_url': base.replace(REPO, observed)}, enrolled)
        for url in [base.replace('https:', 'http:'), base.replace('api.github.com', 'API.GITHUB.COM'),
                    base.replace('api.github.com', 'api.github.com:443'),
                    base.replace('api.github.com', 'user@api.github.com'),
                    base.replace('/check-runs/', '/CHECK-RUNS/'), base + '?x=1', base + '#fragment',
                    base.replace('/100', '/0100')]:
            with self.subTest(url=url):
                self.assertIsNone(normalize_job({**raw_job(), 'check_run_url': url}, REPO)['check_id'])
        huge = '900719925474099312345'
        self.assertEqual(normalize_job(raw_job(check_id=huge), REPO)['check_id'], huge)

    def test_real_client_paginates_runs_jobs_and_checks_under_same_deadline(self):
        calls = []
        def transport(method, url, headers, body, timeout):
            calls.append(url)
            if '/pulls?' in url: payload = [{'number': 7, 'head': {'sha': SHA}}]
            elif '/actions/runs?' in url:
                payload = {'workflow_runs': [raw_run()] if 'page=2' not in url else []}
            elif '/jobs?' in url: payload = {'jobs': [raw_job()] if 'page=2' not in url else []}
            else: payload = {'check_runs': [raw_check()] if 'page=2' not in url else []}
            links = {}
            if '/pulls?' not in url and 'page=2' not in url:
                links['Link'] = '<' + url + '&page=2>; rel="next"'
            return Response(200, links, json.dumps(payload).encode())
        provider = CIProvider(GitHubClient('fixture', transport=transport), INVENTORY)
        sample = provider(time.monotonic() + 5)
        self.assertEqual(len(calls), 17)
        self.assertTrue(sample.data['runs'][0]['actionable'])
        self.assertTrue(all('filter=all' in u for u in calls if '/jobs?' in u))
        self.assertTrue(all('filter=all' in u for u in calls if '/check-runs?' in u))

    def test_independent_actions_run_lineage_preserves_current_head_failure(self):
        # Observed #1698 run/suite lineage; check/app IDs remain synthetic fixtures.
        for event in ('pull_request_review', 'pull_request'):
            failed = raw_run(37148273080); failed['check_suite_id'] = 100623897251; failed['event'] = 'pull_request'
            passed = raw_run(37149201865, 'success'); passed.update(check_suite_id=100626404220, event=event)
            checks = [raw_check(suite=failed['check_suite_id']), raw_check(101, 'success', LATER, suite=passed['check_suite_id'])]
            class Client:
                def pages(self, route, **kwargs):
                    if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                    if '/actions/runs?' in route: return [failed, passed] if 'created=' in route else []
                    if '/jobs?' in route: return [raw_job()] if '/37148273080/' in route else [raw_job(21, 101)]
                    return checks
            rows = CIProvider(Client(), INVENTORY)(time.monotonic() + 5).data['runs']
            old = next(row for row in rows if row['id'] == '37148273080')
            self.assertFalse(old['superseded']); self.assertTrue(old['actionable']); self.assertEqual(old['severity'], 'bump')
            self.assertIsNone(old['checks'][0]['superseded_by'])

    def test_provider_same_run_retry_and_ambiguous_suite_lineage(self):
        for ambiguous in (False, True):
            run = raw_run(conclusion='success'); run['run_attempt'] = 2
            peer = raw_run(11, 'success')
            class Client:
                def pages(self, route, **kwargs):
                    if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                    if '/actions/runs?' in route: return ([run, peer] if ambiguous else [run]) if 'created=' in route else []
                    if '/jobs?' in route: return [raw_job(), {**raw_job(21, 101), 'run_attempt': 2, 'conclusion': 'success'}]
                    return [raw_check(), raw_check(101, 'success', LATER)]
            row = CIProvider(Client(), INVENTORY)(time.monotonic() + 5).data['runs'][0]
            self.assertEqual(row['superseded'], not ambiguous)
            self.assertEqual(row['actionable'], ambiguous)
            self.assertEqual(row['checks'][0]['superseded_by'], None if ambiguous else '101')

    def test_open_head_keeps_actions_lineage_after_its_runs_age_past_the_window(self):
        # #1819: a completed run older than the window leaves the run list while its check-runs stay
        # on the open HEAD. Lineage comes from the runs listed by head_sha, so a same-run retry still
        # supersedes the failure; an unrelated failure, another run of the workflow, a run listed on
        # another SHA and an unlisted run never clear anything.
        now = [1791300000.0]  # 2026-10-06T15:20:00Z; window cutoff 12:00:00Z
        def iso(value): return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        aged = now[0] - 5 * 3600
        retried = raw_run(40, 'success'); retried.update(run_attempt=2, check_suite_id=70, created_at=iso(aged))
        unrelated = raw_run(41); unrelated.update(workflow_id=8, check_suite_id=71, created_at=iso(aged))
        independent = raw_run(42, 'success'); independent.update(check_suite_id=72, created_at=iso(aged + 120))
        elsewhere = {**raw_run(43, 'success', OTHER_SHA), 'check_suite_id': 70, 'created_at': iso(aged)}
        failed = raw_check(300, 'failure', iso(aged), suite=70)
        retry = raw_check(301, 'success', iso(aged + 60), suite=70)
        build = raw_check(302, 'failure', iso(aged), name='build', suite=71)
        other_run = raw_check(303, 'success', iso(aged + 180), suite=72)
        cases = (('same-run retry', [retried], [failed, retry], {'300': '301'}, False),
                 ('retry beside an unrelated failure', [retried, unrelated], [failed, retry, build], {'300': '301', '302': None}, True),
                 ('another run of the workflow', [retried, independent], [failed, other_run], {'300': None}, True),
                 ('a run listed on another SHA', [elsewhere], [failed, retry], {'300': None}, True),
                 ('no run listed for the HEAD', [], [failed, retry], {'300': None}, True))
        for label, head_runs, head_checks, superseded_by, actionable in cases:
            with self.subTest(case=label):
                calls = []
                class Client:
                    def pages(self, route, **kwargs):
                        calls.append({'route': route, **kwargs})
                        if '/pulls?' in route: return [{'number': 7, 'head': {'sha': SHA}}]
                        if '/actions/runs?' in route and 'head_sha=' in route: return list(head_runs)
                        if '/actions/runs?' in route: return []  # every run is older than the window
                        if '/commits/' + SHA + '/check-runs?filter=all' in route: return [copy.deepcopy(c) for c in head_checks]
                        raise AssertionError('unexpected route: ' + route)
                provider = CIProvider(Client(), INVENTORY, clock=lambda: now[0], monotonic=lambda: 0)
                data = provider(5).data
                self.assertEqual(data['runs'], [], 'head_sha runs add lineage, not rows')
                row = next(r for r in data['check_rows'] if r['sha'] == SHA)
                self.assertEqual({c['id']: c['superseded_by'] for c in row['checks'] if c['conclusion'] == 'failure'}, superseded_by)
                self.assertEqual(row['actionable'], actionable); self.assertEqual(row['superseded'], not actionable)
                self.assertEqual(row['severity'], 'bump' if actionable else None)
                if head_runs == [retried]:
                    self.assertEqual({c['id']: (c['producer'], c['workflow_run_id']) for c in row['checks']},
                                     {'300': ('app:1:workflow:9', '40'), '301': ('app:1:workflow:9', '40')})
                head_reads = [c for c in calls if 'head_sha=' in c['route']]
                self.assertEqual([c['route'] for c in head_reads], [f'/repos/{REPO}/actions/runs?head_sha={SHA}&per_page=100'])
                self.assertEqual((head_reads[0]['max_pages'], head_reads[0]['deadline'], head_reads[0]['collection']), (10, 4.75, 'workflow_runs'))
                # The head_sha URL has no time component, so its ETag survives the hourly cutoff.
                calls.clear(); now[0] += 3600; provider(5); now[0] -= 3600
                self.assertEqual([c['route'] for c in calls if 'head_sha=' in c['route']], [f'/repos/{REPO}/actions/runs?head_sha={SHA}&per_page=100'])
        # A HEAD whose Actions checks are all mapped by the window list reads no head_sha runs.
        fixture = unmatched_checks_fixture(checks=[raw_check(conclusion='success')])
        self.assertEqual([c['route'] for c in fixture['calls'] if 'head_sha=' in c['route']], [])

    def test_denied_repo_preserves_other_repo_and_prior_age(self):
        now = [1000]
        class Client:
            denied = False
            def pages(self, path, **kwargs):
                if self.denied and path.startswith('/repos/owner/repo/'):
                    raise ClientError('permission_denied')
                return []
        client = Client()
        provider = CIProvider(client, INVENTORY + (Repository('other', 'owner/other'),), clock=lambda: now[0])
        sample = provider(time.monotonic() + 5).data
        self.assertFalse(sample['repositories'][0]['stale'])
        client.denied = True; now[0] = 2000
        sample = provider(time.monotonic() + 5).data
        self.assertTrue(sample['repositories'][0]['stale'])
        self.assertEqual(sample['repositories'][0]['observed_at'], 1000)
        self.assertEqual(sample['repositories'][0]['error'], 'permission_denied')
        self.assertFalse(sample['repositories'][1]['stale'])
        self.assertEqual(sample['repositories'][1]['observed_at'], 2000)

    def test_initial_denial_page_limit_and_malformed_remain_unknown(self):
        for error in [ClientError('permission_denied'), ClientError('page_limit'), RuntimeError('secret text')]:
            class Client:
                def pages(self, *args, **kwargs): raise error
            data = CIProvider(Client(), INVENTORY)(time.monotonic() + 1).data
            self.assertEqual(data['runs'], [])
            self.assertIsNone(data['repositories'][0]['observed_at'])
            self.assertNotIn('secret text', json.dumps(data))

    def test_deadline_reserves_publication_shares_it_fairly_and_rotates_repository_priority(self):
        # #1817: one slow repository cannot starve the rest. Each repository may first spend an equal
        # share of what remains; unspent time carries forward and the last one gets everything left.
        # A repository that ran out of its share is retried with whatever time the others left.
        mono, calls = [0.0], []
        class Client:
            def pages(self, path, *, deadline, **kwargs):
                calls.append((path, deadline))
                if path.startswith('/repos/owner/repo/'):
                    mono[0] = deadline
                    raise ClientError('deadline_exceeded')
                return []
        provider = CIProvider(Client(), INVENTORY + (Repository('other', 'owner/other'),), monotonic=lambda: mono[0], clock=lambda: 1000)
        first = provider(1).data
        self.assertEqual(calls[0], ('/repos/owner/repo/pulls?state=open&per_page=100', .375))
        self.assertEqual({deadline for path, deadline in calls if '/owner/other/' in path}, {.75})
        self.assertEqual([deadline for path, deadline in calls if '/owner/repo/' in path], [.375, .75])
        self.assertEqual([(o['stale'], o['error']) for o in first['repositories']], [(True, 'deadline_exceeded'), (False, None)])
        mono[0] = 1; calls.clear()
        second = provider(2).data
        self.assertIn('/owner/other/', calls[0][0])
        self.assertFalse(second['repositories'][1]['stale'])
        self.assertEqual(second['repositories'][1]['observed_at'], 1000)
        self.assertTrue(second['repositories'][0]['stale'])
        self.assertEqual({deadline for path, deadline in calls if '/owner/other/' in path}, {1.375})
        self.assertEqual([deadline for path, deadline in calls if '/owner/repo/' in path], [1.75])

    def test_repository_that_ran_out_of_its_share_completes_with_the_time_others_left(self):
        # #1817: a plain equal split left 15 to 20 seconds of a calm scan unused while mergepath
        # and fiveacross, each needing about 12 seconds, stayed stale behind their 7.5-second shares.
        mono, calls = [0.0], []
        class Client:
            def pages(self, path, *, deadline, **kwargs):
                calls.append((path, deadline))
                if path.startswith('/repos/owner/repo/pulls'):
                    if deadline - mono[0] < .5:
                        mono[0] = deadline
                        raise ClientError('deadline_exceeded')
                    mono[0] += .5
                return []
        provider = CIProvider(Client(), INVENTORY + (Repository('other', 'owner/other'), Repository('third', 'owner/third')),
                              monotonic=lambda: mono[0], clock=lambda: 1000)
        data = provider(1.25).data
        deadlines = [deadline for path, deadline in calls if path.startswith('/repos/owner/repo/pulls')]
        self.assertEqual(len(deadlines), 2); self.assertAlmostEqual(deadlines[0], 1 / 3); self.assertEqual(deadlines[1], 1.0)
        self.assertEqual([(o['stale'], o['error']) for o in data['repositories']], [(False, None)] * 3)
        # The other repositories were scanned once each, inside their own shares.
        self.assertEqual(sum(path.startswith('/repos/owner/other/pulls') for path, _ in calls), 1)
        self.assertEqual(sum(path.startswith('/repos/owner/third/pulls') for path, _ in calls), 1)
        # Its last scan needed .5 seconds, more than its next share, so it waits for pass two without
        # spending that share; failing there is its one failure this callback, counted once.
        mono[0] = 10; calls.clear(); provider._offset = 0
        data = provider(10.6).data
        self.assertEqual([deadline for path, deadline in calls if path.startswith('/repos/owner/repo/pulls')], [10.35])
        self.assertEqual(provider._failures['owner/repo'], 1)
        self.assertEqual((data['repositories'][0]['stale'], data['repositories'][0]['error']), (True, 'deadline_exceeded'))
        # A retry is never deferred again, even when its failure leaves budget unspent.
        attempts = []
        class Instant:
            def pages(self, path, *, deadline, **kwargs):
                if path.startswith('/repos/owner/repo/'):
                    attempts.append(deadline)
                    if len(attempts) > 2:
                        raise AssertionError('deferred twice')
                    raise ClientError('deadline_exceeded')
                return []
        data = CIProvider(Instant(), INVENTORY, monotonic=lambda: 0, clock=lambda: 1000)(5).data
        self.assertEqual(len(attempts), 1, 'the only repository already had the whole budget')
        attempts.clear()
        instant = CIProvider(Instant(), INVENTORY + (Repository('other', 'owner/other'),), monotonic=lambda: 0, clock=lambda: 1000)
        data = instant(5).data
        self.assertEqual(attempts, [2.375, 4.75])
        self.assertEqual(data['repositories'][0]['error'], 'deadline_exceeded')
        # The retry after running out of a share does not count a second failure.
        self.assertEqual(instant._failures['owner/repo'], 1)

    def test_repository_known_to_need_more_than_its_share_goes_straight_to_pass_two(self):
        # #1817 review: a restarted scan walks every run-list page again at nearly full cost (a 304
        # still takes most of the two seconds a fresh page does), so a repository that needs more than
        # its share and spends it first was stale on every scan that put it early in the rotation,
        # where one scan of everything in turn kept it fresh. Its last scan's duration now sends it
        # straight to pass two; only a repository with no such history spends a share it cannot use.
        mono, walks, cost = [0.0], [], {'repo': 6, 'other': 1}
        class Client:
            def pages(self, path, *, deadline, **kwargs):
                if '/actions/runs?' in path and 'status=' not in path:
                    repo = path.split('/')[3]
                    walks.append(repo)
                    for _ in range(cost[repo]):
                        if mono[0] + 2 > deadline:
                            mono[0] = deadline
                            raise ClientError('deadline_exceeded')
                        mono[0] += 2
                return []
        provider = CIProvider(Client(), INVENTORY + (Repository('other', 'owner/other'),), monotonic=lambda: mono[0], clock=lambda: 1000)
        stale, spent = [], []
        for _ in range(6):
            # The heavy repository comes first every time: the scans where it spent its share.
            started = mono[0]; walks.clear(); provider._offset = 0
            data = provider(started + 20.25).data
            stale.append([o['stale'] for o in data['repositories']]); spent.append(mono[0] - started)
            if len(stale) > 1:
                self.assertEqual(walks.count('repo'), 1, 'a repository known to need more than its share never spends it')
        self.assertEqual(stale, [[True, False]] + [[False, False]] * 5)
        self.assertEqual(spent, [20.0] + [14.0] * 5)
        # Once a scan needs less than its share again, the repository takes its share in pass one.
        cost['repo'] = 1
        for order in (['other', 'repo'], ['repo', 'other']):
            walks.clear(); provider._offset = 0
            data = provider(mono[0] + 20.25).data
            self.assertEqual(walks, order)
            self.assertEqual([o['stale'] for o in data['repositories']], [False, False])

    def test_repository_waiting_for_pass_two_keeps_its_share_reserved(self):
        # A repository sent straight to pass two still counts when later shares are divided, so a
        # repository that never finishes cannot take the time it was owed.
        mono, walks = [0.0], []
        class Client:
            def pages(self, path, *, deadline, **kwargs):
                if '/actions/runs?' in path and 'status=' not in path:
                    repo = path.split('/')[3]
                    walks.append(repo)
                    for _ in range({'repo': 9, 'slow': 100, 'third': 0}[repo]):
                        if mono[0] + 1 > deadline:
                            mono[0] = deadline
                            raise ClientError('deadline_exceeded')
                        mono[0] += 1
                return []
        provider = CIProvider(Client(), INVENTORY + (Repository('slow', 'owner/slow'), Repository('third', 'owner/third')),
                              monotonic=lambda: mono[0], clock=lambda: 1000)
        provider._needed['owner/repo'] = 9  # as its last scan measured: more than its five-second share
        data = provider(15.25).data
        self.assertEqual([(o['repo'], o['stale']) for o in data['repositories']],
                         [('owner/repo', False), ('owner/slow', True), ('owner/third', False)])
        self.assertEqual(walks, ['slow', 'third', 'repo', 'slow'])

    def test_pass_two_cannot_let_a_repository_that_never_finishes_starve_the_others(self):
        # #1821 review (Codex P1): pass two gave each deferred repository everything left, so a
        # repository that never finishes, first in the rotation, left every later deferred repository
        # stale. A known finite need now goes first with the remainder; repositories that ran out
        # last time split what remains evenly, and time one leaves unspent carries forward.
        mono, walks = [0.0], []
        cost = {'repo': 9, 'slow': 100, 'third': 0}
        class Client:
            def pages(self, path, *, deadline, **kwargs):
                if '/actions/runs?' in path and 'status=' not in path:
                    repo = path.split('/')[3]
                    walks.append(repo)
                    for _ in range(cost[repo]):
                        if mono[0] + 1 > deadline:
                            mono[0] = deadline
                            raise ClientError('deadline_exceeded')
                        mono[0] += 1
                return []
        inventory = (Repository('slow', 'owner/slow'),) + INVENTORY + (Repository('third', 'owner/third'),)
        for label, needed, order, end in (('known need', 9, ['third', 'repo', 'slow'], 20.0),
                                          ('ran out last time', math.inf, ['third', 'slow', 'repo'], 19.0)):
            with self.subTest(case=label):
                mono[0] = 0.0; walks.clear()
                provider = CIProvider(Client(), inventory, monotonic=lambda: mono[0], clock=lambda: 1000)
                provider._needed.update({'owner/slow': math.inf, 'owner/repo': needed})
                data = provider(20.25).data
                stale = {o['repo']: o['stale'] for o in data['repositories']}
                self.assertEqual(stale, {'owner/slow': True, 'owner/repo': False, 'owner/third': False})
                # Both wait for pass two. A known need runs first with everything left and the slow
                # repository gets the rest; two that ran out split it, and the slow one, first in the
                # rotation, spends only its half (ten seconds) before the other finishes.
                self.assertEqual(walks, order); self.assertAlmostEqual(mono[0], end)

    def test_running_to_conclusion_on_same_run_identity(self):
        raw = raw_run(); raw['status'] = 'in_progress'; raw['conclusion'] = None
        rows, _ = group_runs(REPO, [raw], {'10': []}, [], {'7': SHA})
        raw['status'] = 'completed'; raw['conclusion'] = 'success'
        final, _ = group_runs(REPO, [raw], {'10': []}, [], {'7': SHA})
        self.assertEqual(rows[0]['key'], final[0]['key'])
        self.assertEqual(final[0]['conclusion'], 'success')

    def test_untouched_deadline_does_not_inflate_or_reset_real_failure_backoff(self):
        for prior_failures, retry_after in ((0, 0), (1, 0), (2, 0), (0, 60), (1, 60)):
            with self.subTest(prior_failures=prior_failures, retry_after=retry_after):
                now, mono, calls = [1000.0], [0.0], []
                class Client:
                    def pages(self, route, **kwargs):
                        calls.append(route)
                        raise ClientError('upstream_unavailable', retry_after=retry_after)
                provider = CIProvider(Client(), INVENTORY, clock=lambda: now[0], monotonic=lambda: mono[0])
                for _ in range(prior_failures):
                    data = provider(5).data
                    now[0] = data['repositories'][0]['retry_at'] + 1
                dispatched = len(calls)
                for _ in range(6):
                    mono[0] = 5
                    record = provider(5).data['repositories'][0]
                    self.assertEqual(record['error'], 'deadline_exceeded')
                    self.assertEqual(record['retry_at'], now[0])
                self.assertEqual(len(calls), dispatched)
                mono[0] = 0
                record = provider(5).data['repositories'][0]
                self.assertEqual(len(calls), dispatched + 1)
                self.assertEqual(record['retry_at'] - now[0], max(20 * 2 ** prior_failures, retry_after))


class ExcerptTests(unittest.TestCase):
    def test_osc_bel_and_st_terminators_preserve_failure_text(self):
        for terminator in (b'\x07', b'\x1b\\'):
            opening = b'\x1b]8;;https://example.test/log' + terminator
            closing = b'\x1b]8;;' + terminator
            for body, expected in (
                    (b'\x1b]0;title' + terminator + b'FAIL: wanted', 'FAIL: wanted'),
                    (opening + closing + b'FAIL: wanted', 'FAIL: wanted'),
                    (opening + b'FAIL: wanted' + closing + b' suffix', 'FAIL: wanted suffix'),
                    (b'FAIL: before ' + opening + b'linked' + closing + b' after', 'FAIL: before linked after'),
                    (b'\x1b[31m' + opening + b'FAIL: colored' + closing + b'\x1b[0m', 'FAIL: colored')):
                with self.subTest(terminator=terminator, body=body):
                    result = extract_fail_lines(body, {})
                    self.assertEqual(result['status'], 'ok')
                    self.assertEqual(result['lines'], [expected])
                    self.assertEqual(result['scope'], 'job')

    def test_unterminated_osc_preserves_existing_end_of_line_behavior(self):
        result = extract_fail_lines(b'FAIL: retained \x1b]8;;unterminated\n'
                                    b'\x1b]0;title FAIL: hidden\nFAIL: next line', {})
        self.assertEqual(result['lines'], ['FAIL: retained ', 'FAIL: next line'])
        self.assertEqual(result['status'], 'ok')

    def test_osc_at_body_cap_retains_failure_and_existing_output_bounds(self):
        prefix, suffix = b'\x1b]0;', b'\x1b\\FAIL: wanted'
        body = prefix + b'x' * (MAX_BODY - len(prefix) - len(suffix)) + suffix
        self.assertEqual(extract_fail_lines(body, {})['lines'], ['FAIL: wanted'])
        with self.assertRaises(ClientError) as error:
            extract_fail_lines(body + b'x', {})
        self.assertEqual(error.exception.category, 'response_too_large')
        linked = b'\x1b]8;;https://example.test\x1b\\FAIL: ' + b'x' * 2000 + b'\x1b]8;;\x1b\\\n'
        result = extract_fail_lines(linked * 100, {})
        self.assertTrue(result['truncated'])
        self.assertTrue(result['lines'])
        self.assertTrue(all(line == 'FAIL: ' + 'x' * 994 for line in result['lines']))
        self.assertLessEqual(len(result['lines']), 80)
        self.assertLessEqual(sum(len(line.encode()) for line in result['lines']), 32768)

    def test_transient_result_is_shared_by_existing_waiter_but_explicit_retry_reads_again(self):
        for error in ['deadline_exceeded', 'upstream_backoff', 'secondary_limit', 'primary_reserve',
                      'primary_exhausted', 'upstream_unavailable', 'upstream_http_error']:
            with self.subTest(error=error):
                entered, waiting, release = threading.Event(), threading.Event(), threading.Event()
                calls, results = [], {}
                class ObservedCondition(threading.Condition):
                    def wait(self, timeout=None):
                        waiting.set()
                        return super().wait(timeout)
                def read(*args):
                    calls.append(args)
                    if len(calls) == 1:
                        entered.set(); release.wait(2)
                        raise ClientError(error)
                    return b'FAIL: explicit retry'
                cache = LogExcerptCache(INVENTORY, read)
                cache.condition = ObservedCondition()
                def fetch(name):
                    results[name] = cache.handle(params(), envelope(), deadline=time.monotonic()+3)
                leader = threading.Thread(target=fetch, args=('leader',))
                waiter = threading.Thread(target=fetch, args=('waiter',))
                try:
                    leader.start(); self.assertTrue(entered.wait(1))
                    waiter.start(); self.assertTrue(waiting.wait(1))
                finally:
                    release.set(); leader.join(2)
                    if waiter.ident is not None: waiter.join(2)
                self.assertFalse(leader.is_alive() or waiter.is_alive())
                self.assertEqual(len(calls), 1)
                self.assertEqual(results['leader'], results['waiter'])
                self.assertEqual(results['waiter']['error'], error)
                self.assertEqual(len(cache.cache), 0); self.assertEqual(len(cache.pending), 0)
                retry = cache.handle(params(), envelope(), deadline=time.monotonic()+1)
                self.assertEqual(retry['lines'], ['FAIL: explicit retry'])
                self.assertEqual(len(calls), 2)

    def test_coalesced_waiter_deadline_does_not_cancel_leader_or_block_retry(self):
        now = [0]
        entered, waiting, release = threading.Event(), threading.Event(), threading.Event()
        calls, results = [], {}
        class ObservedCondition(threading.Condition):
            def wait(self, timeout=None):
                waiting.set()
                return super().wait(timeout)
        def read(*args):
            calls.append(args)
            if len(calls) == 1:
                entered.set(); release.wait(2)
                raise ClientError('upstream_unavailable')
            return b'FAIL: recovered'
        cache = LogExcerptCache(INVENTORY, read, clock=lambda: now[0])
        cache.condition = ObservedCondition()
        def fetch(name, deadline): results[name] = cache.handle(params(), envelope(), deadline=deadline)
        leader = threading.Thread(target=fetch, args=('leader', 10))
        waiter = threading.Thread(target=fetch, args=('waiter', 1))
        try:
            leader.start(); self.assertTrue(entered.wait(1))
            waiter.start(); self.assertTrue(waiting.wait(1))
            with cache.condition:
                now[0] = 2; cache.condition.notify_all()
            waiter.join(1); self.assertFalse(waiter.is_alive())
            self.assertEqual(results['waiter']['error'], 'deadline_exceeded')
            self.assertTrue(leader.is_alive()); self.assertEqual(len(calls), 1)
        finally:
            release.set(); leader.join(2)
            if waiter.ident is not None: waiter.join(2)
        self.assertEqual(results['leader']['error'], 'upstream_unavailable')
        self.assertEqual(len(cache.pending), 0)
        self.assertEqual(cache.handle(params(), envelope(), deadline=3)['lines'], ['FAIL: recovered'])
        self.assertEqual(len(calls), 2)

    def test_excerpt_retry_honors_shared_client_backoff_then_observes_recovery(self):
        now, calls = [1000], []
        def transport(*args):
            calls.append(args)
            if len(calls) == 1:
                return Response(403, {'Retry-After': '60'}, b'secondary rate limit')
            return Response(302, {'Location': 'https://productionresultssa19.blob.core.windows.net/logs/job.txt?sig=fixture'}, b'')
        client = GitHubClient('fixture', transport=transport, clock=lambda: now[0],
                              log_transport=lambda *args: Response(200, {}, b'FAIL: recovered'))
        cache = LogExcerptCache(INVENTORY, lambda repo, job, deadline: client.read_job_log(repo, job, deadline=deadline))
        self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()+1)['error'], 'secondary_limit')
        self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()+1)['error'], 'upstream_backoff')
        self.assertEqual(len(calls), 1)
        now[0] += 60
        self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()+1)['lines'], ['FAIL: recovered'])
        self.assertEqual(len(calls), 2)

    def test_explicit_retry_after_transient_failure_can_observe_log_immediately(self):
        for error in ['deadline_exceeded', 'upstream_backoff', 'secondary_limit', 'primary_reserve',
                      'primary_exhausted', 'upstream_unavailable', 'upstream_http_error']:
            calls = []
            def read(*args):
                calls.append(args)
                if len(calls) == 1: raise ClientError(error)
                return b'FAIL: retry observed'
            cache = LogExcerptCache(INVENTORY, read)
            with self.subTest(error=error):
                self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()+1)['error'], error)
                retry = cache.handle(params(), envelope(), deadline=time.monotonic()+1)
                self.assertEqual(retry['lines'], ['FAIL: retry observed'])
                self.assertEqual(len(calls), 2)

    def test_expired_request_before_read_does_not_poison_next_retry(self):
        calls = []
        def read(*args):
            calls.append(args); return b'FAIL: new request'
        cache = LogExcerptCache(INVENTORY, read)
        self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()-1)['error'], 'deadline_exceeded')
        self.assertEqual(calls, [])
        self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()+1)['lines'], ['FAIL: new request'])
        self.assertEqual(len(calls), 1)

    def test_deterministic_denial_and_oversize_remain_cached_for_ttl(self):
        for error in ['permission_denied', 'response_too_large']:
            now, calls = [0], []
            def read(*args):
                calls.append(args); raise ClientError(error)
            cache = LogExcerptCache(INVENTORY, read, clock=lambda: now[0])
            for at in [0, 119]:
                now[0] = at
                self.assertEqual(cache.handle(params(), envelope(), deadline=at+1)['error'], error)
            self.assertEqual(len(calls), 1)
            now[0] = 120
            self.assertEqual(cache.handle(params(), envelope(), deadline=121)['error'], error)
            self.assertEqual(len(calls), 2)

    def test_cache_truncated_start_second_falls_back_to_whole_job_on_read_and_hit(self):
        for start in ['2026-10-03T00:00:10Z', '2026-10-03T00:00:10.0000000Z']:
            for prior in ['2026-10-03T00:00:10Z', '2026-10-03T00:00:10.2500000Z']:
                with self.subTest(start=start, prior=prior):
                    job = raw_job(); job['steps'][0]['started_at'] = start
                    data = model(); data['runs'][0]['jobs'] = [normalize_job(job)]
                    body = (prior + ' FAIL: prior step before actual start at .800\n'
                            '2026-10-03T00:00:20.2500000Z FAIL: selected step\n'
                            '2026-10-03T00:01:01Z FAIL: next step').encode()
                    reads = []
                    def read(*args):
                        reads.append(args); return body
                    cache = LogExcerptCache(INVENTORY, read)
                    for _ in range(2):
                        result = cache.handle(params(), envelope(data), deadline=time.monotonic()+1)
                        self.assertEqual(result['scope'], 'job')
                        self.assertEqual(result['lines'], ['FAIL: prior step before actual start at .800',
                                                          'FAIL: selected step', 'FAIL: next step'])
                        self.assertEqual(result['source'], 'Actions job log')
                        self.assertEqual(result['status'], 'ok')
                    self.assertEqual(len(reads), 1)

    def test_cache_precise_start_and_interior_only_failures_retain_step_window(self):
        body = (b'2026-10-03T00:00:10.2500000Z FAIL: prior step\n'
                b'2026-10-03T00:00:10.8000000Z FAIL: exact precise start\n'
                b'2026-10-03T00:00:20.2500000Z FAIL: selected step\n'
                b'2026-10-03T00:01:01Z FAIL: next step')
        job = raw_job(); job['steps'][0]['started_at'] = '2026-10-03T00:00:10.8000000Z'
        data = model(); data['runs'][0]['jobs'] = [normalize_job(job)]
        reads = []
        def read(*args):
            reads.append(args); return body
        cache = LogExcerptCache(INVENTORY, read)
        for _ in range(2):
            result = cache.handle(params(), envelope(data), deadline=time.monotonic()+1)
            self.assertEqual(result['scope'], 'step-time-window')
            self.assertEqual(result['lines'], ['FAIL: exact precise start', 'FAIL: selected step'])
        # Reproject the same cached job bytes for a whole-second start whose
        # second has no FAIL lines; unrelated failures remain outside the window.
        job['steps'][0]['started_at'] = '2026-10-03T00:00:11Z'
        data['runs'][0]['jobs'] = [normalize_job(job)]
        result = cache.handle(params(), envelope(data), deadline=time.monotonic()+1)
        self.assertEqual(result['scope'], 'step-time-window')
        self.assertEqual(result['lines'], ['FAIL: selected step'])
        self.assertEqual(len(reads), 1)

    def test_cache_ambiguous_start_fallback_preserves_bounded_chronological_tail(self):
        body = (b'2026-10-03T00:00:10.2500000Z FAIL: ambiguous prior step\n' +
                b'\n'.join(('2026-10-03T00:02:00Z FAIL: later ' + str(i)).encode() for i in range(100)))
        job = raw_job(); job['steps'][0]['started_at'] = '2026-10-03T00:00:10Z'
        data = model(); data['runs'][0]['jobs'] = [normalize_job(job)]
        cache = LogExcerptCache(INVENTORY, lambda *args: body)
        result = cache.handle(params(), envelope(data), deadline=time.monotonic()+1)
        self.assertEqual(result['scope'], 'job')
        self.assertEqual(result['source'], 'Actions job log')
        self.assertTrue(result['truncated'])
        self.assertEqual(result['lines'], ['FAIL: later ' + str(i) for i in range(20, 100)])
        self.assertLessEqual(sum(len(line.encode()) for line in result['lines']), 32768)

    def test_timestamp_window_excludes_other_steps(self):
        step = normalize_job(raw_job())['steps'][0]
        result = extract_fail_lines(b'2026-10-02T23:59:00Z FAIL: before\n2026-10-03T00:00:10Z FAIL: wanted\n2026-10-03T00:02:00Z FAIL: after', step)
        self.assertEqual(result['lines'], ['FAIL: wanted'])
        self.assertEqual(result['scope'], 'step-time-window')

    def test_fractional_completion_second_and_untimed_failures_fall_back_to_job(self):
        instant = datetime.datetime.fromisoformat('2026-10-03T00:00:10+00:00').timestamp()
        step = {'started_at': instant, 'completed_at': instant}
        result = extract_fail_lines(b'2026-10-03T00:00:10.2500000Z FAIL: selected or adjacent\n2026-10-03T00:00:11Z FAIL: adjacent', step)
        self.assertEqual(result['scope'], 'job')
        self.assertEqual(result['lines'], ['FAIL: selected or adjacent', 'FAIL: adjacent'])
        result = extract_fail_lines(b'FAIL: untimed failure', step)
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(result['scope'], 'job')
        self.assertEqual(result['lines'], ['FAIL: untimed failure'])

    def test_job_scope_explicit_when_step_times_missing_empty_and_hostile(self):
        result = extract_fail_lines(b'\x1b[31mFAIL: <img src=x onerror=evil()>\x1b[0m\x00\nError: separate diagnostic', {})
        self.assertEqual(result['scope'], 'job')
        self.assertEqual(result['lines'], ['FAIL: <img src=x onerror=evil()>'])
        self.assertEqual(extract_fail_lines(b'Error: no FAIL lines', {})['status'], 'empty')
        bounded = extract_fail_lines(('FAIL: ' + 'x' * 2000 + '\n').encode() * 100, {})
        self.assertTrue(bounded['truncated'])
        self.assertLessEqual(len(bounded['lines']), 80)
        self.assertLessEqual(sum(len(x.encode()) for x in bounded['lines']), 32768)

    def test_tail_retains_latest_failure_and_chronological_order(self):
        body = '\n'.join('FAIL: line ' + str(i) for i in range(100)).encode()
        result = extract_fail_lines(body, {})
        self.assertTrue(result['truncated'])
        self.assertEqual(len(result['lines']), 80)
        self.assertEqual(result['lines'][0], 'FAIL: line 20')
        self.assertEqual(result['lines'][-1], 'FAIL: line 99')
        self.assertNotIn('FAIL: line 0', result['lines'])

    def test_observed_identity_refusal_stale_denied_and_cache(self):
        calls = []
        def read(repo, job, deadline):
            calls.append((repo, job))
            raise ClientError('permission_denied')
        cache = LogExcerptCache(INVENTORY, read)
        for update in [{'repo': 'https://evil'}, {'run': '99'}, {'job': '$(touch x)'}, {'step': '1'}, {'url': 'https://evil'}]:
            with self.assertRaises(ValueError): cache.handle(params(**update), envelope(), deadline=time.monotonic()+1)
        self.assertEqual(cache.handle(params(), envelope(stale=True), deadline=time.monotonic()+1)['status'], 'stale')
        self.assertEqual(calls, [])
        for _ in range(2): self.assertEqual(cache.handle(params(), envelope(), deadline=time.monotonic()+1)['status'], 'denied')
        self.assertEqual(calls, [(REPO, '20')])

    def test_repeated_requests_coalesce_and_body_is_bounded(self):
        entered, release = threading.Event(), threading.Event()
        calls, results = [], []
        def read(repo, job, deadline):
            calls.append(job); entered.set(); release.wait(1)
            return b'2026-10-03T00:00:10Z FAIL: once'
        cache = LogExcerptCache(INVENTORY, read)
        def fetch(): results.append(cache.handle(params(), envelope(), deadline=time.monotonic()+2))
        a = threading.Thread(target=fetch); b = threading.Thread(target=fetch)
        a.start(); self.assertTrue(entered.wait(1)); b.start(); release.set()
        a.join(2); b.join(2)
        self.assertFalse(a.is_alive() or b.is_alive())
        self.assertEqual(calls, ['20'])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]['lines'], ['FAIL: once'])
        large = LogExcerptCache(INVENTORY, lambda *args: b'x' * (2 * 1024 * 1024 + 1))
        self.assertEqual(large.handle(params(), envelope(), deadline=time.monotonic()+1)['error'], 'response_too_large')

    def test_repo_stale_refuses_without_losing_whole_source(self):
        data = model(); data['repositories'][0]['stale'] = True
        cache = LogExcerptCache(INVENTORY, lambda *args: self.fail('unexpected fetch'))
        self.assertEqual(cache.handle(params(), envelope(data), deadline=time.monotonic()+1)['status'], 'stale')


if __name__ == '__main__': unittest.main()
