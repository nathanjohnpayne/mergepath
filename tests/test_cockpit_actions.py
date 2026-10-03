"""Hermetic Actions source coverage; no credential or live GitHub calls."""
import datetime as dt
import json
import unittest
from types import SimpleNamespace

from mergepath.cockpit.actions import ActionsProvider, billing_usage, ci_observation, measured_coefficient, run_rows
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

    def test_cycle_configuration_must_match_api_period(self):
        now=dt.datetime.fromtimestamp(NOW,dt.timezone.utc)
        start=now.replace(day=1,hour=0,minute=0,second=0).timestamp();end=(now.replace(day=28)+dt.timedelta(days=4)).replace(day=1,hour=0,minute=0,second=0).timestamp()
        value=self.provider(settings={'budget':25,'cycle_start':start,'cycle_end':end}).fetch(30).data['configuration']
        self.assertEqual(value['cycle_end'],end)
        value=self.provider(settings={'budget':25,'cycle_start':start+1,'cycle_end':end}).fetch(30).data['configuration']
        self.assertIsNone(value['cycle_end'])


if __name__ == '__main__':
    unittest.main()
