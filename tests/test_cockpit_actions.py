"""Hermetic Actions source coverage; no credential or live GitHub calls."""
import datetime as dt
import json
import subprocess
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from mergepath.cockpit.actions import JOB_PAGES, ActionsProvider, billing_usage, ci_observation, measured_coefficient, run_rows
from mergepath.cockpit.github import ClientError, GitHubClient, Response, copy_json_tree

NOW = 1791028800  # 2026-10-03 UTC
REPO = 'nathanjohnpayne/mergepath'


def run(identity=1, status='completed', created=NOW, conclusion='success', message=None):
    value = {'id': identity, 'status': status, 'created_at': dt.datetime.fromtimestamp(created, dt.timezone.utc).isoformat(), 'conclusion': conclusion}
    if message is not None:
        value['failure_message'] = message
    return value


class Fake:
    def __init__(self):
        self.calls = []
        self.billing = {'usageItems': [{'product': 'Actions', 'netAmount': 0, 'grossAmount': 1000, 'repositoryName': 'mergepath'}]}
        self.queued, self.running, self.hour = [], [], []
        self.error = None

    def get(self, path, *, deadline):
        self.calls.append((path, deadline))
        if isinstance(self.billing, Exception):
            raise self.billing
        return self.billing

    def pages(self, path, **kwargs):
        self.calls.append((path, kwargs))
        if self.error:
            raise self.error
        return self.queued if 'status=queued' in path else self.running if 'status=in_progress' in path else self.hour


class ActionsTests(unittest.TestCase):
    def provider(self, fake=None, **kwargs):
        return ActionsProvider(fake or Fake(), [SimpleNamespace(repo=REPO)], clock=lambda: NOW, monotonic=lambda: 0, **kwargs)

    def test_net_only_and_attribution(self):
        value = billing_usage({'usageItems': [
            {'product': 'Actions', 'netAmount': 0, 'grossAmount': 999, 'repositoryName': 'public'},
            {'product': 'Actions', 'netAmount': 1.1, 'repositoryName': 'mergepath'},
            {'product': 'Actions', 'netAmount': 2.2, 'repositoryName': 'mergepath'},
            {'product': 'Packages', 'netAmount': 999},
            {'product': 'Actions', 'netAmount': 2}]}, 'nathanjohnpayne', NOW)
        self.assertEqual(value['net_amount'], 5.3)
        self.assertEqual(value['repositories'][0]['net_amount'], 3.3)
        self.assertEqual(value['unattributed'], 2)
        self.assertEqual(value['workflow_attribution'], 'unavailable')

    def test_invalid_billing_is_not_partial_success(self):
        for amount in [None, '3', True, float('nan'), float('inf'), -1, 10 ** 10]:
            with self.subTest(amount=amount), self.assertRaises(ClientError):
                billing_usage({'usageItems': [{'product': 'Actions', 'netAmount': 2}, {'product': 'Actions', 'netAmount': amount}]}, 'o', NOW)
        with self.assertRaises(ClientError):
            billing_usage({'usageItems': [{'product': 'Actions', 'net_amount': 2, 'grossAmount': 2}]}, 'o', NOW)

    def test_documented_qualified_billing_identity_and_bare_fallback(self):
        payload = {'usageItems': [
            {'product': 'Actions', 'netAmount': 0.8, 'grossAmount': 999, 'repositoryName': 'user/example'},
            {'product': 'Actions', 'netAmount': 0.2, 'repositoryName': 'example'},
            {'product': 'Actions', 'netAmount': 0.4, 'repositoryName': 'other-owner/example'},
            {'product': 'Actions', 'netAmount': 0.3}]}
        value = billing_usage(payload, 'user', NOW)
        self.assertEqual(value['net_amount'], 1.7)
        self.assertEqual(value['unattributed'], 0.3)
        self.assertEqual(value['repositories'], [
            {'repo': 'user/example', 'net_amount': 1.0},
            {'repo': 'other-owner/example', 'net_amount': 0.4}])
        fake = Fake(); fake.billing = payload
        sample = self.provider(fake, settings={'billing_owner': 'user'}).fetch(30).data
        self.assertTrue(sample['billing']['available'])
        self.assertEqual(sample['billing']['repositories'], value['repositories'])
        billing_calls = [path for path, _ in fake.calls if '/settings/billing/' in path]
        self.assertEqual(billing_calls, ['/users/user/settings/billing/usage?year=2026&month=10'])
        self.assertTrue(all(path.startswith(f'/repos/{REPO}/') for path, _ in fake.calls if path.startswith('/repos/')))
        self.assertFalse(any('other-owner' in path for path, _ in fake.calls))

    def test_malformed_billing_repository_refuses_whole_observation(self):
        for repository in ['user/example/extra', '/example', 'user/', 'bad owner/example',
                           'user/example?secret', 'user/' + 'x' * 201, 17, True]:
            with self.subTest(repository=repository), self.assertRaises(ClientError):
                billing_usage({'usageItems': [
                    {'product': 'Actions', 'netAmount': 2},
                    {'product': 'Actions', 'netAmount': 1, 'repositoryName': repository}]}, 'user', NOW)

    def test_measurement_provenance_unicode_codepoint_boundary(self):
        measurement = {'repo': REPO, 'requests': 800, 'runs': 2,
                       'window_start': NOW-600, 'window_end': NOW-100, 'observed_at': NOW-50}
        for length in (121, 240, 241):
            provenance = '\U0001f600' * length
            with self.subTest(length=length):
                value = measured_coefficient({**measurement, 'provenance': provenance}, REPO, NOW)
                if length <= 240:
                    self.assertEqual(value['requests_per_run'], 400)
                    self.assertEqual(value['provenance'], provenance)
                else:
                    self.assertIsNone(value)

    def test_padded_provenance_survives_provider_to_js_without_accepting_controls(self):
        content = '\U0001f600' * 240
        inner_space = '\U0001f600' * 119 + ' ' + '\U0001f600' * 120
        cases = [(padding + content + padding, content) for padding in (' ', '\u0085', '\u2003')]
        cases += [(' ' + inner_space + ' ', inner_space), ('\n' + content, None), ('\t' + content, None)]
        script = ('const input=JSON.parse(require("node:fs").readFileSync(0,"utf8"));'
                  'const card=require("./mergepath/cockpit/assets/actions.js").project(input,null,input.observed_at).cards[1];'
                  'console.log(JSON.stringify({available:card.available,value:card.rows[0].value,detail:card.rows[0].detail}));')
        for provenance, expected in cases:
            with self.subTest(provenance=repr(provenance[:2])):
                measurement = {'repo': REPO, 'requests': 800, 'runs': 2,
                               'window_start': NOW-600, 'window_end': NOW-100,
                               'observed_at': NOW-50, 'provenance': provenance}
                fake = Fake(); fake.hour = [run(1), run(2)]
                provider = self.provider(fake, settings={'measurements': {REPO: measurement}})
                sample = provider.fetch(30).data
                self.assertEqual(provider.settings['measurements'][REPO]['provenance'], provenance)
                row = sample['repositories'][0]
                output = subprocess.run(['node', '-e', script], cwd=Path(__file__).resolve().parents[1],
                                        input=json.dumps({'data': sample, 'stale': False, 'observed_at': NOW}),
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(output.returncode, 0, output.stderr)
                card = json.loads(output.stdout)
                if expected is None:
                    self.assertIsNone(row['measurement']); self.assertIsNone(row['estimated_requests'])
                    self.assertFalse(card['available']); self.assertIn('unavailable', card['value'])
                else:
                    self.assertEqual(row['estimated_requests'], 800)
                    self.assertTrue(card['available']); self.assertTrue(card['value'].startswith('est.'))
                    self.assertEqual(row['measurement']['provenance'], expected)
                    self.assertIn(expected, card['detail'])

    def test_denied_billing_independent_and_slow(self):
        f = Fake(); f.billing = ClientError('permission_denied'); f.queued = [run(1,'queued')]
        p = self.provider(f)
        first = p.fetch(30).data
        self.assertFalse(first['billing']['available'])
        self.assertEqual(first['repositories'][0]['queued'], 1)
        self.assertFalse(first['robot']['available'])
        self.assertIsNone(first['repositories'][0]['estimated_requests'])
        p.fetch(30)
        self.assertEqual(sum('/settings/billing/' in path for path, _ in f.calls), 1)
        copy_json_tree(first)  # Returned data has no aliases or non-native values.

    def test_billing_cache_revalidates_on_utc_month_and_year_rollover(self):
        for year, month in [(2026, 10), (2026, 12)]:
            with self.subTest(year=year, month=month):
                start = dt.datetime(year, month, 1, tzinfo=dt.timezone.utc)
                end = (start.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
                current = [end.timestamp() - 60]
                f = Fake(); f.billing['usageItems'][0]['netAmount'] = 25
                p = ActionsProvider(f, [SimpleNamespace(repo=REPO)],
                                    clock=lambda: current[0], monotonic=lambda: 0)
                prior = p.fetch(30).data['billing']
                self.assertEqual((prior['year'], prior['month']), (year, month))
                current[0] = end.timestamp() + 60
                f.billing['usageItems'][0]['netAmount'] = 1
                new = p.fetch(30).data['billing']
                self.assertTrue(new['available']); self.assertFalse(new['stale'])
                self.assertEqual((new['year'], new['month']), (end.year, end.month))
                self.assertEqual(new['net_amount'], 1)
                self.assertEqual(new['observed_at'], current[0])
                calls = [path for path, _ in f.calls if '/settings/billing/' in path]
                self.assertEqual(len(calls), 2)
                self.assertIn(f'year={end.year}&month={end.month}', calls[-1])
                p.fetch(30)
                self.assertEqual(sum('/settings/billing/' in path for path, _ in f.calls), 2)

    def test_denied_month_rollover_retains_prior_period_stale_without_retry_storm(self):
        boundary = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc).timestamp()
        current = [boundary - 60]
        f = Fake(); f.billing['usageItems'][0]['netAmount'] = 25
        p = ActionsProvider(f, [SimpleNamespace(repo=REPO)],
                            clock=lambda: current[0], monotonic=lambda: 0)
        prior = p.fetch(30).data['billing']
        current[0] = boundary + 60
        f.billing = ClientError('permission_denied')
        denied = p.fetch(30).data['billing']
        self.assertFalse(denied['available']); self.assertTrue(denied['stale'])
        self.assertEqual(denied['error'], 'permission_denied')
        self.assertEqual((denied['year'], denied['month']), (2026, 10))
        self.assertEqual(denied['net_amount'], 25)
        self.assertEqual(denied['observed_at'], prior['observed_at'])
        current[0] += 1
        p.fetch(30)
        self.assertEqual(sum('/settings/billing/' in path for path, _ in f.calls), 2)
        current[0] += 1800
        f.billing = {'usageItems': [{'product': 'Actions', 'netAmount': 1}]}
        recovered = p.fetch(30).data['billing']
        self.assertTrue(recovered['available'])
        self.assertEqual((recovered['year'], recovered['month']), (2026, 11))
        # A denial with no last-good report is also scoped to the attempted month.
        current[0] = boundary - 60
        first_denied = Fake(); first_denied.billing = ClientError('permission_denied')
        p = ActionsProvider(first_denied, [SimpleNamespace(repo=REPO)],
                            clock=lambda: current[0], monotonic=lambda: 0)
        self.assertFalse(p.fetch(30).data['billing']['available'])
        current[0] = boundary + 60
        first_denied.billing = {'usageItems': [{'product': 'Actions', 'netAmount': 2}]}
        self.assertEqual(p.fetch(30).data['billing']['net_amount'], 2)
        self.assertEqual(sum('/settings/billing/' in path for path, _ in first_denied.calls), 2)

    def test_measurement_provenance_expiry_and_estimate(self):
        measurement = {'repo': REPO, 'requests': 800, 'runs': 2, 'window_start': NOW-600, 'window_end': NOW-100, 'observed_at': NOW-50, 'provenance': 'local run counters'}
        f = Fake(); f.hour = [run(1),run(2)]
        p = self.provider(f,settings={'measurements':{REPO:measurement}})
        row = p.fetch(30).data['repositories'][0]
        self.assertEqual(row['estimated_requests'],800)
        self.assertEqual(row['measurement']['provenance'],'local run counters')
        self.assertIsNone(measured_coefficient({**measurement,'observed_at':NOW-4000,'window_end':NOW-4100,'window_start':NOW-4500},REPO,NOW))
        for key, value in [('runs',0),('requests',True),('repo','other/repo'),('provenance','x\nsecret'),('window_end',NOW+1)]:
            self.assertIsNone(measured_coefficient({**measurement,key:value},REPO,NOW))

    def test_installation_message_requires_failed_recent_bound_run(self):
        rows = run_rows([run(1,conclusion='failure',message='API rate limit exceeded for installation 7'),run(2,conclusion='failure'),run(3,message='API rate limit exceeded for installation'),run(4,created=NOW-3601,conclusion='failure',message='API rate limit exceeded for installation')],REPO,NOW)
        self.assertEqual([r['id'] for r in rows if r['installation_exhausted']],['1'])

    def test_jam_positive_time_consecutive_success_and_reset(self):
        f = Fake(); f.queued=[run(i,'queued') for i in range(1,41)]; f.running=[run(41,'in_progress')]
        current = [NOW]
        p = ActionsProvider(f,[SimpleNamespace(repo=REPO)],clock=lambda:current[0],monotonic=lambda:0)
        self.assertFalse(p.fetch(30).data['repositories'][0]['jammed'])
        for offset in range(120,1801,120):
            current[0]=NOW+offset
            self.assertFalse(p.fetch(30).data['repositories'][0]['jammed'])
        current[0]=NOW+1801
        self.assertTrue(p.fetch(30).data['repositories'][0]['jammed'])
        f.error=ClientError('secondary_limit'); current[0]+=1
        failed=p.fetch(30).data['repositories'][0]
        self.assertFalse(failed['available']); self.assertTrue(failed['stale'])
        f.error=None; current[0]+=1
        self.assertFalse(p.fetch(30).data['repositories'][0]['jammed'])
        current[0]+=1810
        self.assertFalse(p.fetch(30).data['repositories'][0]['jammed'])

    def test_repeated_snapshot_cannot_manufacture_jam(self):
        observed=[NOW]
        snapshot=lambda repo,now: {'complete':True,'stale':False,'observed_at':observed[0], 'queued':[run(i,'queued') for i in range(1,41)],'running':[],'hour':[]}
        p=self.provider(ci_snapshot=snapshot)
        self.assertFalse(p.fetch(30).data['repositories'][0]['jammed'])
        self.assertFalse(p.fetch(30).data['repositories'][0]['jammed'])
        self.assertEqual(sum('actions/runs' in path for path,_ in p.client.calls),0)

    def test_repeated_snapshot_retains_proven_jam_without_aging_interval(self):
        current, observed = [NOW], [NOW]
        snapshot = lambda repo, now: {"complete": True, "stale": False,
            "observed_at": observed[0], "queued": [run(i, "queued") for i in range(1, 41)],
            "running": [run(41, "in_progress")], "hour": []}
        p = ActionsProvider(Fake(), [SimpleNamespace(repo=REPO)],
                            clock=lambda: current[0], monotonic=lambda: 0, ci_snapshot=snapshot)
        self.assertFalse(p.fetch(30).data["repositories"][0]["jammed"])
        for offset in range(120, 1801, 120):
            current[0] = observed[0] = NOW + offset
            self.assertFalse(p.fetch(30).data["repositories"][0]["jammed"])
        current[0] = observed[0] = NOW + 1801
        proven = p.fetch(30).data["repositories"][0]
        self.assertTrue(proven["jammed"])
        # Another poll sees exactly the same successful CI observation.
        current[0] += 1
        repeated = p.fetch(30).data["repositories"][0]
        self.assertTrue(repeated["jammed"])
        self.assertEqual(repeated["observed_at"], proven["observed_at"])
        self.assertEqual(repeated["jam_since"], proven["jam_since"])
        # Once the copied observation expires, it cannot remain fresh proof.
        current[0] = observed[0] + 121
        missing = p.fetch(30).data["repositories"][0]
        self.assertFalse(missing["available"])
        self.assertTrue(missing["stale"])
        observed[0] = current[0]
        recovered = p.fetch(30).data["repositories"][0]
        self.assertFalse(recovered["jammed"])
        self.assertEqual(recovered["jam_since"], observed[0])

    def test_fair_deadline_rotation_and_local_reserve(self):
        f=Fake(); p=ActionsProvider(f,[SimpleNamespace(repo=REPO),SimpleNamespace(repo='owner/second')],clock=lambda:NOW,monotonic=lambda:0)
        p.fetch(30)
        deadlines=[params['deadline'] for path,params in f.calls if 'actions/runs' in path]
        self.assertEqual(deadlines[:3],[10,10,10])
        f.calls=[];p.fetch(30)
        self.assertIn('owner/second',f.calls[0][0])
        calls=[]
        def transport(method,url,headers,body,timeout):
            calls.append(url)
            return Response(200,{'X-RateLimit-Limit':'5000','X-RateLimit-Remaining':'100','X-RateLimit-Reset':str(NOW+3600)},json.dumps([]).encode())
        client=GitHubClient('synthetic',transport=transport,clock=lambda:NOW,monotonic=lambda:0)
        client.get('/repos/owner/test/actions/runs',deadline=30)
        with self.assertRaises(ClientError) as context:
            client.get('/repos/owner/test/actions/runs',deadline=30)
        self.assertEqual(context.exception.category,'primary_reserve');self.assertEqual(len(calls),1)

    def test_paginated_runs_and_etag_revalidation(self):
        calls=[]
        def transport(method,url,headers,body,timeout):
            calls.append((url,headers))
            if 'page=2' in url:
                return Response(200,{},json.dumps({'workflow_runs':[run(2,'queued')]}).encode())
            return Response(200,{'ETag':'"q"','Link':'<https://api.github.com/repos/nathanjohnpayne/mergepath/actions/runs?page=2>; rel="next"'},json.dumps({'workflow_runs':[run(1,'queued')]}).encode())
        client=GitHubClient('synthetic',transport=transport,clock=lambda:NOW,monotonic=lambda:0)
        path='/repos/'+REPO+'/actions/runs?status=queued'
        self.assertEqual(len(client.pages(path,collection='workflow_runs',deadline=30)),2)
        client.pages(path,collection='workflow_runs',deadline=30)
        self.assertEqual(calls[2][1]['If-None-Match'],'"q"')

    def test_robot_is_separate_and_secondary_wins(self):
        source={'configured_identity':'nathanpayne-robot','observed_at':NOW,'reset':NOW+3600,'remaining':4900,'limit':5000,'secondary_limited':True,'repositories':{'secret':20}}
        value=self.provider(robot_snapshot=lambda:source).fetch(30).data['robot']
        self.assertTrue(value['secondary_limited']);self.assertEqual(value['remaining'],4900);self.assertIsNone(value['repositories'])
        cached=self.provider(robot_snapshot=lambda:source)
        self.assertTrue(cached.fetch(30).data['robot']['available'])
        original=source.copy();source.clear()
        retained=cached.fetch(30).data['robot']
        self.assertFalse(retained['available']);self.assertTrue(retained['secondary_limited']);self.assertEqual(retained['configured_identity'],'nathanpayne-robot')
        source.update(original)
        source['reset']=NOW-1
        expired=self.provider(robot_snapshot=lambda:source).fetch(30).data['robot']
        self.assertFalse(expired['available']);self.assertTrue(expired['secondary_limited'])
        source['configured_identity']='nathanpayne-codex'
        self.assertFalse(self.provider(robot_snapshot=lambda:source).fetch(30).data['robot']['available'])

    def test_ci_read_only_all_repo_complete_and_dedup(self):
        row={'id':'2','repo':REPO,'created_at':NOW,'status':'queued','conclusion':None,'checks':[]}
        envelope={'stale':False,'data':{'schema':'ci/v1','recent_seconds':86400,'repositories':[{'repo':REPO,'stale':False,'observed_at':NOW}],'runs':[row,row.copy()]}}
        value=ci_observation(envelope,REPO,NOW)
        self.assertEqual(len(value['queued']),1);self.assertEqual(len(value['hour']),1)
        row.update(conclusion='failure',checks=[{'conclusion':'failure','diagnostic':'API rate limit exceeded for installation 2'}])
        hard=ci_observation(envelope,REPO,NOW)
        self.assertEqual(run_rows(hard['hour'],REPO,NOW)[0]['installation_exhausted'],True)
        envelope['data']['repositories'][0]['stale']=True
        self.assertIsNone(ci_observation(envelope,REPO,NOW))
        envelope['data']['repositories'][0]['stale']=False
        envelope['data']['recent_seconds']=300
        self.assertIsNone(ci_observation(envelope,REPO,NOW))

    def test_registered_ci_publication_feeds_actions_without_duplicate_reads(self):
        from mergepath.cockpit.ci import CIProvider
        from mergepath.cockpit.inventory import Repository
        from mergepath.cockpit.server import Application
        calls, denied = [], [False]
        current = [NOW]
        observed_run = {**run(21, 'queued', conclusion=None), 'run_attempt': 1,
                        'head_sha': 'a' * 40, 'name': 'lint', 'workflow_id': 9,
                        'check_suite_id': 50, 'pull_requests': []}
        def transport(method, url, headers, body, timeout):
            calls.append(url)
            if '/settings/billing/' in url:
                payload = {'usageItems': []}
            elif denied[0]:
                return Response(403, {}, b'{}')
            elif '/pulls?' in url:
                payload = []
            elif '/actions/runs?' in url:
                payload = {'workflow_runs': [observed_run] if 'status=queued' in url or 'created=' in url else []}
            elif '/jobs?' in url:
                payload = {'jobs': []}
            elif '/check-runs?' in url:
                payload = {'check_runs': []}
            else:
                self.fail('unexpected request: ' + url)
            return Response(200, {}, json.dumps(payload).encode())
        inventory = (Repository('mergepath', REPO, True),)
        client = GitHubClient('synthetic-integration-token', transport=transport, clock=lambda: current[0])
        app = Application(inventory, client, clock=lambda: current[0])
        self.addCleanup(app.close)
        provider = CIProvider(client, inventory, clock=lambda: current[0])
        app.scheduler.register('ci', provider)
        app.register_panel('ci', 'ci')
        actions = ActionsProvider(client, inventory, clock=lambda: current[0],
            ci_snapshot=lambda repo, now: ci_observation(app.panel_snapshot('ci')['envelope'], repo, now))
        first = actions.fetch(time.monotonic() + 5).data['repositories'][0]
        self.assertFalse(first['available'])
        self.assertTrue(all('/settings/billing/' in url for url in calls))
        def publish_ci():
            before = app.snapshot()['revision']
            app.scheduler.refresh('ci')
            app.scheduler.tick()
            bound = time.monotonic() + 3
            while time.monotonic() < bound:
                envelope = app.panel_snapshot('ci')['envelope']
                if app.snapshot()['revision'] > before and not envelope['in_flight']:
                    return envelope
                time.sleep(.005)
            self.fail('CI publication did not complete')
        fresh = publish_ci()
        self.assertFalse(fresh['data']['repositories'][0]['stale'])
        before = len(calls)
        reused = actions.fetch(time.monotonic() + 5).data['repositories'][0]
        self.assertTrue(reused['available']); self.assertEqual(reused['queued'], 1)
        self.assertEqual(len(calls), before)
        denied[0] = True; current[0] += 1
        stale = publish_ci()
        self.assertTrue(stale['data']['repositories'][0]['stale'])
        before = len(calls)
        retained = actions.fetch(time.monotonic() + 5).data['repositories'][0]
        self.assertFalse(retained['available']); self.assertTrue(retained['stale'])
        self.assertEqual(retained['queued'], 1)
        self.assertEqual(retained['observed_at'], reused['observed_at'])
        self.assertEqual(len(calls), before)

    def test_shared_ci_publication_after_fetch_clock_retains_jam(self):
        from mergepath.cockpit.__main__ import shared_ci_snapshot
        from mergepath.cockpit.ci import CIProvider
        from mergepath.cockpit.inventory import Repository
        from mergepath.cockpit.server import Application
        current, interleave, reads = [NOW], [False], []
        def transport(method, url, headers, body, timeout):
            reads.append(url)
            self.assertIn('/settings/billing/', url)  # No duplicate Actions poll.
            return Response(200, {}, b'{"usageItems":[]}')
        inventory = (Repository('mergepath', REPO, True),)
        client = GitHubClient('synthetic-integration-token', transport=transport, clock=lambda: current[0])
        app = Application(inventory, client, clock=lambda: current[0])
        self.addCleanup(app.close)
        ci = CIProvider(client, inventory, clock=lambda: current[0])
        rows = [{'id': str(i), 'repo': REPO, 'created_at': NOW - 30, 'status': 'queued',
                 'conclusion': None, 'checks': []} for i in range(1, 41)]
        # Only remote acquisition is replaced. Real CIProvider stamps times;
        # real scheduler publication and Application snapshot copying are used.
        ci._repo = lambda repo, deadline: (rows, [], [])
        app.scheduler.register('ci', ci, hot_interval=1, idle_interval=1, timeout=5)
        app.register_panel('ci', 'ci')
        original_snapshot = app.panel_snapshot
        def publish_ci():
            app.scheduler.refresh('ci'); app.scheduler.tick()
            bound = time.monotonic() + 2
            while time.monotonic() < bound:
                envelope = original_snapshot('ci')['envelope']
                if not envelope['in_flight'] and envelope['observed_at'] == current[0]:
                    return
                time.sleep(.001)
            self.fail('bounded CI publication did not complete')
        def snapshot(panel):
            if interleave[0]:
                interleave[0] = False
                current[0] += .01
                publish_ci()  # After fetch-clock capture, before snapshot copy.
            return original_snapshot(panel)
        app.panel_snapshot = snapshot
        actions = ActionsProvider(client, inventory, clock=lambda: current[0],
            ci_snapshot=lambda repo, now: shared_ci_snapshot(app, repo, now))
        def fetch():
            return actions.fetch(time.monotonic() + 5).data['repositories'][0]
        for offset in range(0, 1861, 60):
            current[0] = NOW + offset
            publish_ci(); proven = fetch()
        self.assertTrue(proven['available'])
        self.assertFalse(proven['stale'])
        self.assertEqual(proven['queued'], 40)
        self.assertTrue(proven['jammed'])
        interleave[0] = True
        raced = fetch()
        self.assertTrue(raced['available']); self.assertFalse(raced['stale'])
        self.assertEqual(raced['observed_at'], current[0])
        self.assertGreater(raced['observed_at'], proven['observed_at'])
        self.assertTrue(raced['jammed']); self.assertEqual(raced['jam_since'], proven['jam_since'])
        # Reusing the same receipt preserves proof but cannot age the interval.
        current[0] += 1
        repeated = fetch()
        self.assertTrue(repeated['jammed']); self.assertEqual(repeated['observed_at'], raced['observed_at'])
        self.assertEqual(actions._jam[REPO]['last'], raced['observed_at'])
        publish_ci(); following = fetch()
        self.assertTrue(following['jammed']); self.assertEqual(following['jam_since'], proven['jam_since'])
        self.assertTrue(all('/settings/billing/' in url for url in reads))

    def test_budget_panel_row_freshness_matches_the_ci_observation_gap(self):
        import re
        from mergepath.cockpit.ci import OBSERVATION_GAP
        source = (Path(__file__).resolve().parents[1] / 'mergepath/cockpit/assets/actions.js').read_text()
        self.assertEqual(int(re.search(r'const CI_OBSERVATION_GAP = (\d+);', source).group(1)), OBSERVATION_GAP)

    def test_installation_scan_reads_failed_job_logs_independently_of_the_ci_snapshot(self):
        # nathanpaynedotcom 2026-10-07: gates printed the installation limit only in job logs, and
        # the CI scan could not cover that repository at all.
        iso = lambda at: dt.datetime.fromtimestamp(at, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        R = lambda i, attempt=1, created=NOW: {'id': i, 'run_attempt': attempt, 'created_at': iso(created)}
        state = {'runs': [R(5), R(6, 2)], 'error': None}
        jobs = {5: [{'id': 51, 'conclusion': 'failure'}, {'id': 52, 'conclusion': 'success'}],
                6: [{'id': 61, 'conclusion': 'failure'}], 7: [{'id': i, 'conclusion': 'failure'} for i in (71, 72, 73, 74)]}
        logs = {'51': b'gh: API rate limit exceeded for installation. If you reach out', '61': b'other failure',
                '71': b'x', '72': b'x', '73': b'x', '74': b'API rate limit exceeded for installation'}
        reads, gets, current, oversized, cut = [], [], [NOW], set(), set()
        class ScanFake(Fake):
            def get(self, path, *, deadline):
                if '/settings/billing/' in path:
                    return super().get(path, deadline=deadline)
                gets.append(path)
                if state['error']:
                    raise ClientError(state['error'])
                assert 'status=failure' in path and 'per_page=5' in path, path
                return {'workflow_runs': state['runs']}
            def pages(self, path, *, collection=None, max_pages=10, deadline=None):
                if '/jobs?' not in path:
                    return super().pages(path, collection=collection, max_pages=max_pages, deadline=deadline)
                gets.append(path)
                # Jobs of every attempt, every page under the scan bound; a longer list fails, never truncates.
                assert '/attempts/' not in path and 'filter=all' in path, path
                assert (collection, max_pages) == ('jobs', JOB_PAGES), (collection, max_pages)
                run_id = int(path.split('/runs/')[1].split('/')[0])
                if run_id in oversized:
                    raise ClientError('page_limit')
                return jobs[run_id]
            def read_job_log(self, repo, job, *, deadline):
                reads.append(job)
                if job in cut:
                    cut.discard(job); raise ClientError('deadline_exceeded')
                return logs[job]
        stale = lambda repo, now: {'complete': True, 'stale': True, 'observed_at': NOW, 'queued': [], 'running': [], 'hour': []}
        p = ActionsProvider(ScanFake(), [SimpleNamespace(repo=REPO)], clock=lambda: current[0], monotonic=lambda: 0,
                            ci_snapshot=stale, installation_scan=True)
        scan = lambda: p.fetch(30).data['repositories'][0]['installation_scan']
        def step(seconds=121):
            current[0] += seconds; reads.clear(); gets.clear(); return scan()
        row = p.fetch(30).data['repositories'][0]
        # The CI snapshot is stale, yet the scan still establishes exhaustion for run 5. Scan runs
        # travel apart from the CI-derived installation_runs, which the stale snapshot lacks.
        self.assertFalse(row['available']); self.assertIn(row.get('installation_runs'), (None, []))
        self.assertEqual(row['installation_scan'], {'observed_at': NOW, 'error': None, 'runs': ['5']})
        # The first logged limit settles the scan, so run 6 is never read.
        self.assertEqual(reads, ['51'])
        # Within the interval nothing is read again; after it, jobs and verdicts come from the cache.
        self.assertEqual((step(60), gets, reads), (row['installation_scan'], [], []))
        step(61); self.assertEqual((len(gets), reads), (1, []))
        # At most three log reads per scan. An incomplete scan is not clean evidence: the last
        # settled runs stand with their time.
        state['runs'] = [R(7)]; settled = current[0]
        partial = step()
        self.assertEqual(reads, ['71', '72', '73']); self.assertEqual(partial, {'observed_at': settled, 'error': 'incomplete', 'runs': ['5']})
        # A settled scan samples only the newest runs and cannot disprove an earlier proof inside
        # the hour, so run 5 stands beside run 7, newest first.
        done = step(); self.assertEqual(done, {'observed_at': current[0], 'error': None, 'runs': ['7', '5']})
        # A failed read keeps the last runs and their observation time, and names the error.
        state['error'] = 'secondary_limit'
        self.assertEqual(step(), {'observed_at': done['observed_at'], 'error': 'secondary_limit', 'runs': ['7', '5']})
        # An exhausting repository adds fresh failed runs faster than every job could be read
        # (285 in an hour on nathanpaynedotcom): one proven exhaustion is a complete answer even
        # with unread jobs left, while a clean answer still needs every failed job read.
        state.update(error=None, runs=[R(i, created=NOW + 600) for i in (8, 9, 10, 11, 12)])
        jobs.update({i: [{'id': i * 10 + 1, 'conclusion': 'failure'}] for i in (8, 9, 10, 11, 12)})
        logs.update({'81': b'other failure', **{str(i * 10 + 1): b'API rate limit exceeded for installation' for i in (9, 10, 11, 12)}})
        storm = step(); self.assertEqual(reads, ['81', '91'])
        self.assertEqual(storm, {'observed_at': current[0], 'error': None, 'runs': ['9', '7', '5']})
        # A cached proof settles the scan even when the read cap left earlier jobs unread.
        state['runs'] = [R(13, created=NOW + 600), R(9, created=NOW + 600)]
        jobs[13] = [{'id': i, 'conclusion': 'failure'} for i in (131, 132, 133, 134)]
        logs.update({str(i): b'x' for i in (131, 132, 133, 134)})
        capped = step(); self.assertEqual(reads, ['131', '132', '133'])
        self.assertEqual(capped, {'observed_at': current[0], 'error': None, 'runs': ['9', '7', '5']})
        # The jobs of every attempt are read: an earlier attempt can hold the limit a rerun hides.
        state['runs'] = [R(19, attempt=2, created=NOW + 600)]
        jobs[19] = [{'id': 191, 'conclusion': 'failure', 'run_attempt': 1}, {'id': 192, 'conclusion': 'failure', 'run_attempt': 2}]
        logs.update({'191': b'API rate limit exceeded for installation', '192': b'other failure'})
        self.assertEqual(step()['runs'][0], '19'); self.assertEqual(reads, ['191'])
        # An attempt list longer than the page bound fails the scan instead of reading as clean.
        state['runs'] = [R(14, created=NOW + 600)]; oversized.add(14)
        big = step(); self.assertEqual(big['error'], 'page_limit'); self.assertEqual(big['runs'][0], '19')
        # A failed job row that cannot be read fails the scan rather than vanishing from it.
        for index, bad_jobs in enumerate(([{'conclusion': 'failure'}], [{'id': 0, 'conclusion': 'failure'}], ['x'],
                                          [{'id': True, 'conclusion': 'failure'}], [{'id': 42}], [{'id': 42, 'conclusion': None}],
                                          [{'id': 42, 'conclusion': 'FAILURE'}])):
            jobs[160 + index] = bad_jobs; state['runs'] = [R(160 + index, created=NOW + 600)]
            self.assertEqual(step()['error'], 'invalid_page', bad_jobs)
        # Every failure-class conclusion is read, and every documented finished one is accepted.
        jobs[20] = [{'id': 201, 'conclusion': 'stale'}, {'id': 202, 'conclusion': 'cancelled'}, {'id': 203, 'conclusion': 'timed_out'}]
        logs['203'] = b'API rate limit exceeded for installation'; state['runs'] = [R(20, created=NOW + 600)]
        timed = step(); self.assertEqual(reads, ['203']); self.assertEqual((timed['error'], timed['runs'][0]), (None, '20'))
        # A listed run needs a zoned creation time.
        for created in (None, '2026-10-03T00:00:00', 'soon'):
            state['runs'] = [{'id': 17, 'run_attempt': 1, 'created_at': created}]
            self.assertEqual(step()['error'], 'invalid_page', created)
        # Evidence is the exact last hour: the coarse URL cutoff admits up to five extra minutes,
        # and a settled scan drops proofs whose runs have left the hour.
        # A proof leaving its hour inside the scan interval ends the cached answer: the scan runs again.
        state['runs'] = [R(20, created=NOW + 600)]; current[0] = NOW + 3600 - 60 - 121; before = step()
        self.assertEqual((before['error'], before['runs']), (None, ['20', '19', '9', '7', '5']))
        within = step(61); self.assertEqual(len(gets), 1, 'the cache is bypassed once runs 5 and 7 expire')
        self.assertEqual(within, {'observed_at': current[0], 'error': None, 'runs': ['20', '19', '9']})
        self.assertEqual((step(30), gets), (within, []))
        # A scan the deadline cut short retries on the next tick, advancing from its caches.
        jobs[21] = [{'id': 211, 'conclusion': 'failure'}]; logs['211'] = b'API rate limit exceeded for installation'
        state['runs'] = [R(21, created=NOW + 600)]; cut.add('211')
        self.assertEqual(step()['error'], 'deadline_exceeded')
        retried = step(15); self.assertEqual((reads, retried['error'], retried['runs'][0]), (['211'], None, '21'))
        within = retried; self.assertEqual((step(15), gets), (retried, []))
        # A retry stays inside its window's three log reads, and a pending retry keeps the source hot.
        jobs[23] = [{'id': i, 'conclusion': 'failure'} for i in (231, 232, 233, 234)]
        logs.update({str(i): b'x' for i in (231, 232, 233, 234)}); state['runs'] = [R(23, created=NOW + 600)]; cut.add('232')
        current[0] += 121; reads.clear(); cutting = p.fetch(30)
        self.assertEqual(cutting.data['repositories'][0]['installation_scan']['error'], 'deadline_exceeded'); self.assertEqual(reads, ['231', '232'])
        self.assertTrue(cutting.hot, 'a deadline-cut scan is retried on the hot cadence')
        current[0] += 15; settled = p.fetch(30)
        self.assertEqual(reads, ['231', '232', '232']); self.assertEqual(settled.data['repositories'][0]['installation_scan']['error'], 'incomplete')
        self.assertFalse(settled.hot)
        # A rescan forced by a proof expiring inside the window keeps that window's log reads.
        expiry = ActionsProvider(ScanFake(), [SimpleNamespace(repo=REPO)], clock=lambda: current[0], monotonic=lambda: 0,
                                 ci_snapshot=stale, installation_scan=True)
        jobs[24] = [{'id': i, 'conclusion': 'failure'} for i in (241, 242, 243, 244)]
        logs.update({str(i): b'x' for i in (241, 242, 243, 244)})
        state['runs'] = [R(24, created=current[0])]; reads.clear()
        expiry._scans[REPO] = {'attempted_at': current[0] - 10, 'observed_at': current[0] - 10, 'error': None, 'runs': ['99'],
                               'proofs': {'99': current[0] - 3601}, 'retry': False, 'window': current[0] - 10, 'reads': 3}
        gets.clear(); rescanned = expiry.fetch(30).data['repositories'][0]['installation_scan']
        self.assertEqual((len(gets) > 0, reads, rescanned['error'], rescanned['runs']), (True, [], 'incomplete', []), 'the expired proof rescans, but the window has no reads left')
        current[0] += 10; expiry.fetch(30); self.assertEqual(reads, [])
        # A run dated ahead of this clock waits until it enters the window.
        jobs[22] = [{'id': 221, 'conclusion': 'failure'}]; logs['221'] = b'API rate limit exceeded for installation'
        state['runs'] = [R(22, created=current[0] + 121 + 30)]
        # It took a sample slot, so the scan is incomplete rather than clean.
        ahead = step(121); self.assertEqual((reads, ahead['error']), ([], 'incomplete')); self.assertNotIn('22', ahead['runs'])
        within = ahead
        # Proofs expire with their hour even while every refresh fails.
        state['error'] = 'secondary_limit'; current[0] = NOW + 600 + 3601 - 121
        self.assertEqual(step(), {'observed_at': within['observed_at'], 'error': 'secondary_limit', 'runs': []})
        state['error'] = None
        jobs[18] = [{'id': 181, 'conclusion': 'failure'}]; logs['181'] = b'API rate limit exceeded for installation'
        current[0] = NOW + 600 + 3601; state['runs'] = [R(18, created=current[0] + 121 - 3601)]
        aged = step(); self.assertEqual(reads, []); self.assertEqual(len(gets), 1)
        self.assertEqual(aged, {'observed_at': current[0], 'error': None, 'runs': []})
        state['runs'] = [R(18, created=current[0] + 121 - 3600)]
        self.assertEqual(step()['runs'], ['18']); self.assertEqual(reads, ['181'])
        # A clock that steps back drops a proof dated after it rather than republishing it as current.
        current[0] -= 3600 + 10; reads.clear(); gets.clear()
        back = scan(); self.assertEqual((back['error'], back['runs'], len(gets)), ('incomplete', [], 1))
        # Without the launcher flag the provider makes no reads beside the snapshot.
        quiet = ScanFake(); gets.clear()
        ActionsProvider(quiet, [SimpleNamespace(repo=REPO)], clock=lambda: NOW, monotonic=lambda: 0, ci_snapshot=stale).fetch(30)
        self.assertEqual(gets, [])

    def test_ci_cadence_spacing_establishes_jam_within_the_ci_observation_gap(self):
        # The CI source renews a repository's observation up to OBSERVATION_GAP apart (#1815
        # Phase 4b): 125-second spacing must still prove continuity for an injected snapshot.
        from mergepath.cockpit.ci import HOT_INTERVAL, IDLE_INTERVAL, OBSERVATION_GAP, TIMEOUT
        self.assertGreaterEqual(OBSERVATION_GAP, TIMEOUT + IDLE_INTERVAL + TIMEOUT)
        self.assertLessEqual(HOT_INTERVAL, IDLE_INTERVAL)
        for gap, spacing, jammed in ((OBSERVATION_GAP, 125, True), (OBSERVATION_GAP, OBSERVATION_GAP, True),
                                     (OBSERVATION_GAP, OBSERVATION_GAP + 1, False), (120, 125, False)):
            with self.subTest(gap=gap, spacing=spacing):
                current = [NOW]
                snapshot = lambda repo, now: {'complete': True, 'stale': False, 'observed_at': current[0],
                    'queued': [run(i, 'queued') for i in range(1, 41)], 'running': [], 'hour': []}
                p = ActionsProvider(Fake(), [SimpleNamespace(repo=REPO)], clock=lambda: current[0], monotonic=lambda: 0,
                                    ci_snapshot=snapshot, ci_max_gap=gap)
                rows = []
                while current[0] <= NOW + 1800 + spacing:
                    rows.append(p.fetch(30).data['repositories'][0]); current[0] += spacing
                self.assertTrue(all(row['available'] for row in rows))
                self.assertEqual(rows[-1]['jammed'], jammed)
        # Between scans the injected snapshot ages up to the gap and stays usable; past it, it expires.
        for age, available in ((OBSERVATION_GAP, True), (OBSERVATION_GAP + 1, False)):
            p = self.provider(ci_snapshot=lambda repo, now: {'complete': True, 'stale': False, 'observed_at': NOW - age,
                'queued': [], 'running': [], 'hour': []}, ci_max_gap=OBSERVATION_GAP)
            self.assertEqual(p.fetch(30).data['repositories'][0]['available'], available)
        # The launcher's shared reader applies the same gap to the published envelope.
        from mergepath.cockpit.__main__ import shared_ci_snapshot
        for age, usable in ((200, True), (OBSERVATION_GAP, True), (OBSERVATION_GAP + 1, False)):
            envelope = {'stale': False, 'data': {'schema': 'ci/v1', 'recent_seconds': 10800, 'runs': [],
                'repositories': [{'repo': REPO, 'stale': False, 'error': None, 'observed_at': NOW - age}]}}
            app = SimpleNamespace(clock=lambda: NOW, panel_snapshot=lambda panel: {'envelope': envelope})
            self.assertEqual(shared_ci_snapshot(app, REPO, NOW) is not None, usable, age)
            if age > 120:
                self.assertIsNone(ci_observation(envelope, REPO, NOW), 'the reader default stays 120 seconds')
        for bad in (0, -1, True, float('nan'), 3601, '270'):
            with self.assertRaises(ValueError):
                self.provider(ci_max_gap=bad)

    def test_shared_ci_postcopy_clock_preserves_strict_refusals(self):
        from mergepath.cockpit.__main__ import shared_ci_snapshot
        from mergepath.cockpit.ci import OBSERVATION_GAP
        for case, observed, stale, coverage in [('future', NOW + .01, False, 86400),
                ('expired', NOW - OBSERVATION_GAP - 1, False, 86400), ('stale', NOW, True, 86400),
                ('incomplete', NOW, False, 300)]:
            with self.subTest(case=case):
                envelope = {'stale': False, 'data': {'schema': 'ci/v1', 'recent_seconds': coverage,
                    'repositories': [{'repo': REPO, 'stale': stale, 'observed_at': observed}], 'runs': []}}
                app = SimpleNamespace(clock=lambda: NOW, panel_snapshot=lambda panel: {'envelope': envelope})
                self.assertIsNone(shared_ci_snapshot(app, REPO, NOW - 1))
                actions = self.provider(ci_snapshot=lambda repo, now: shared_ci_snapshot(app, repo, now), ci_max_gap=OBSERVATION_GAP)
                row = actions.fetch(30).data['repositories'][0]
                self.assertFalse(row['available']); self.assertEqual(row['error'], 'source_failed')
                self.assertTrue(all('/settings/billing/' in path for path, _ in actions.client.calls))
        # The provider's independent second guard must also refuse genuinely
        # future or expired normalized callbacks, rather than clamping their time.
        for observed, gap in ((NOW + .01, 120), (NOW - 121, 120), (NOW + .01, OBSERVATION_GAP), (NOW - OBSERVATION_GAP - 1, OBSERVATION_GAP)):
            actions = self.provider(ci_snapshot=lambda repo, now: {'complete': True, 'stale': False,
                'observed_at': observed, 'queued': [], 'running': [], 'hour': []}, ci_max_gap=gap)
            self.assertFalse(actions.fetch(30).data['repositories'][0]['available'])

    def test_cycle_configuration_must_match_api_period(self):
        now=dt.datetime.fromtimestamp(NOW,dt.timezone.utc)
        start=now.replace(day=1,hour=0,minute=0,second=0).timestamp();end=(now.replace(day=28)+dt.timedelta(days=4)).replace(day=1,hour=0,minute=0,second=0).timestamp()
        value=self.provider(settings={'budget':25,'cycle_start':start,'cycle_end':end}).fetch(30).data['configuration']
        self.assertEqual(value['cycle_end'],end)
        value=self.provider(settings={'budget':25,'cycle_start':start+1,'cycle_end':end}).fetch(30).data['configuration']
        self.assertIsNone(value['cycle_end'])


if __name__ == '__main__':
    unittest.main()
