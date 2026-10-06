"""Hermetic CI provider, supersession and on-demand log attribution tests."""

import copy
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
                              'stale': False, 'error': None, 'retry_at': None}]}


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

    def test_deadline_reserves_publication_and_rotates_repository_priority(self):
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
        self.assertEqual(calls[0][1], .75)
        self.assertFalse(any('/owner/other/' in p for p, _ in calls))
        self.assertTrue(all(o['stale'] for o in first['repositories']))
        mono[0] = 1; calls.clear()
        second = provider(2).data
        self.assertIn('/owner/other/', calls[0][0])
        self.assertFalse(second['repositories'][1]['stale'])
        self.assertEqual(second['repositories'][1]['observed_at'], 1000)
        self.assertTrue(second['repositories'][0]['stale'])
        self.assertTrue(all(deadline == 1.75 for _, deadline in calls))

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
