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
from mergepath.cockpit.github import ClientError, GitHubClient, Response, copy_json_tree
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
        self.assertTrue(all('filter=all' in u for u in calls if '/jobs?' in u or '/check-runs?' in u))

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


class ExcerptTests(unittest.TestCase):
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
