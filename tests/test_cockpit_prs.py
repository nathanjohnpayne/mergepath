"""Hermetic #1587 provider/bridge regression fixtures. Expected <10s; bound60s."""
import base64
import copy
import json
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mergepath.cockpit.github import ClientError, GitHubClient, copy_json_tree
from mergepath.cockpit.inventory import Repository
from mergepath.cockpit.prs import HelperReader, PRProvider, build_row, budget, partial_row, exact, load_settings, commits_since_review

ROOT = Path(__file__).resolve().parents[1]
HEAD = 'a' * 40
REPO = 'owner/hub'


def connection(nodes, cursor=None):
    return {'nodes': nodes, 'pageInfo': {'hasNextPage': cursor is not None, 'endCursor': cursor}}


def raw(number=1, **overrides):
    value = dict(number=number, id='P9007199254740993', title='literal <img onerror=bad>', state='OPEN',
                isDraft=False, headRefOid=HEAD, createdAt='2026-10-01T01:00:00Z', updatedAt='2026-10-03T01:00:00Z',
                author={'login': 'author'}, mergeStateStatus='BLOCKED', reviewDecision=None,
                labels=connection([]), commits={'nodes': [{'commit': {'oid': HEAD, 'pushedDate': '2026-10-03T00:00:00Z', 'statusCheckRollup': {'contexts': connection([{'id': '9007199254740993', 'name': 'Required lint', 'isRequired': True, 'status': 'IN_PROGRESS', 'conclusion': None, 'detailsUrl': 'https://github.com/owner/hub/actions/runs/1'}])}}}]})
    value.update(overrides)
    return value


def receipts(head=HEAD, used=0, **overrides):
    values = {'ledger': {'summary': {'requests': used, 'blocking_responses_solicited': used}, 'limits': {'max_blocking_reviews': 10, 'max_review_rounds': 20}, 'human_stops': [], 'in_flight_on_head': True, 'outstanding': 1},
              'feedback': {'accounted': 3, 'posted': 3}, 'coderabbit': {'status': 'reported', 'head_sha': head},
              'commits': {'used': 0}, 'accounting': {'reruns': 0, 'totals': {'tokens_total': '9007199254740993', 'notional_usd': None, 'reported_cost_usd': 1.25}, 'coverage': 'fixture'}}
    values.update(overrides)
    return {key: {'head': head, 'data': value, 'observed_at': 1000, 'stale': False, 'error': None} for key, value in values.items()}


class Client:
    next_cursor = staticmethod(GitHubClient.next_cursor)
    def __init__(self):
        self.rows = [raw()]; self.calls = []; self.failed = False; self.next_page = None; self.label_page = None; self.check_page = None; self.terminal = 'MERGED'
    def query(self, document, variables, *, deadline):
        self.calls.append((document, copy.deepcopy(variables), deadline))
        if self.failed:
            raise ClientError('permission_denied')
        if 'CockpitPRTransitions' in document:
            return {'repository': {'p0': raw(state=self.terminal)}}
        if 'CockpitPRRequired' in document:
            available={value['number']:value for value in self.rows+(self.next_page or [])}
            return {'repository':{alias:copy.deepcopy(available.get(int(number),raw(int(number),state=self.terminal)))
                                  for alias,number in re.findall(r'(p\d+):pullRequest\(number:(\d+)\)',document)}}
        if 'CockpitPRPage' in document:
            return {'repository': {'pullRequest': {'headRefOid': HEAD, 'labels': connection(self.label_page or []),
                'commits': {'nodes': [{'commit': {'oid': HEAD, 'statusCheckRollup': {'contexts': connection(self.check_page or [])}}}]}}}}
        nodes = self.rows if variables.get('cursor') is None else self.next_page or []
        return {'repository': {'pullRequests': connection(copy.deepcopy(nodes), 'second' if self.next_page is not None and variables.get('cursor') is None else None)}}


class Helpers:
    def __init__(self):
        self.calls=[]; self.used=0; self.fail=False
    def read(self, repo, number, head, deadline):
        self.calls.append((repo, number, head, deadline))
        return {key: {'data': None if self.fail else value['data'], 'error': 'source_failed' if self.fail else None} for key, value in receipts(head, self.used).items()}


class PRTests(unittest.TestCase):
    def test_all_budget_boundaries_and_small_limit(self):
        for key in ['blocking', 'requests', 'rounds', 'reruns', 'commits']:
            for used, left, state in [(0, 10, 'clear'), (8, 2, 'bump'), (9, 1, 'bump'), (10, 0, 'boulder'), (11, 0, 'boulder')]:
                item=budget(key,used,10); self.assertEqual((item['remaining'],item['state']),(left,state)); self.assertEqual(item['used'],used)
            self.assertEqual(budget(key,None,10)['remaining'],None)
            self.assertEqual(budget(key,1,None)['state'],'idle')
        self.assertEqual(budget('reruns',0,1)['state'],'clear'); self.assertEqual(budget('reruns',1,1)['state'],'boulder')
        self.assertEqual(budget('reruns',0,1)['threshold'],1)
        self.assertIsNone(budget('rounds',True,10)['used'])

    def test_commit_budget_uses_reviewed_identity_not_old_committer_date(self):
        previous='b'*40
        review={'user':{'login':'coderabbitai[bot]'},'body':'Full review','commit_id':previous,'submitted_at':'2026-10-03T01:00:00Z'}
        commits=[{'sha':previous},{'sha':HEAD,'commit':{'committer':{'date':'2026-09-01T00:00:00Z'}}}]
        self.assertEqual(commits_since_review([review],[],commits,HEAD),1)
        current=copy.deepcopy(review);current['commit_id']=HEAD
        self.assertEqual(commits_since_review([current],[],commits,HEAD),0)
        resumed={'user':{'login':'nathanjohnpayne'},'body':'@coderabbitai resume','created_at':'2026-10-03T02:00:00Z'}
        with self.assertRaises(ClientError):commits_since_review([review],[resumed],commits,HEAD)
        with self.assertRaises(ClientError):commits_since_review([review],[],commits[1:],HEAD)
        with self.assertRaises(ClientError):commits_since_review([review],[],commits,'c'*40)

    def test_required_running_gate_labels_and_clean_fact(self):
        row=build_row(REPO,raw(),receipts(),observed_at=1000)
        self.assertEqual(row['state'],'running'); self.assertIn('Required lint in progress',row['reason'])
        self.assertEqual(row['checks'][0]['id'],'9007199254740993')
        for label in ['needs-external-review','needs-human-review','human-hold','policy-violation']:
            item=raw(labels=connection([{'name':label}]))
            result=build_row(REPO,item,receipts(),observed_at=1000)
            self.assertEqual(result['labels'],[label])
            self.assertEqual(result['state'],'boulder' if label!='needs-external-review' else 'running')
        item=raw();item['mergeStateStatus']='CLEAN'
        result=build_row(REPO,item,receipts(),observed_at=1000)
        self.assertEqual(result['label'],'Clean · GitHub state');self.assertIn('clearance is not asserted',result['reason'])

    def test_spent_unaccounted_unknown_wrong_head_and_precedence(self):
        self.assertEqual(build_row(REPO,raw(),receipts(used=20))['label'],'Budget spent')
        self.assertEqual(build_row(REPO,raw(),receipts(feedback={'accounted':1,'posted':3}))['label'],'Unaccounted')
        self.assertEqual(build_row(REPO,raw(),receipts(coderabbit={'status':'paused','head_sha':HEAD}))['state'],'bump')
        row=build_row(REPO,raw(),receipts(head='b'*40)); self.assertTrue(all(b['remaining'] is None for b in row['budgets']))
        row=build_row(REPO,raw(),None); self.assertIsNone(row['feedback']['posted']);self.assertIsNone(row['spend']['totals'])
        for merge,label in [('DIRTY','Conflicts'),('UNSTABLE','Unstable'),('BEHIND','Behind main')]:
            item=raw();item['mergeStateStatus']=merge; self.assertEqual(build_row(REPO,item,None)['label'],label)
        row=build_row(REPO,raw(isDraft=True),receipts(used=10));self.assertEqual(row['label'],'Budget spent')
        self.assertTrue(row['hazards']);self.assertTrue(row['hazards'][0]['id'].startswith('prs-'))

    def test_same_head_cadence_and_activity_refresh_head_invalidation(self):
        client,helper=Client(),Helpers(); clock=[0]
        provider=PRProvider(client,[Repository('hub',REPO)],ROOT,helper=helper,monotonic=lambda:clock[0],clock=lambda:1000+clock[0])
        self.assertEqual(provider(100).data['repositories'][0]['rows'][0]['budgets'][0]['used'],0)
        helper.used=3;clock[0]=15;provider(100);self.assertEqual(len(helper.calls),1)
        clock[0]=120;self.assertEqual(provider(200).data['repositories'][0]['rows'][0]['budgets'][0]['used'],3)
        client.rows[0]['updatedAt']='2026-10-03T02:00:00Z';clock[0]=130;provider(200);self.assertEqual(len(helper.calls),3)
        client.rows[0]['headRefOid']='b'*40;client.rows[0]['commits']['nodes'][0]['commit']['oid']='b'*40;helper.fail=True;clock[0]=140
        row=provider(200).data['repositories'][0]['rows'][0];self.assertIsNone(row['budgets'][0]['used'])
        self.assertEqual(row['head'],'b'*40)

    def test_request_deadline_leaves_publication_margin_and_rotates_repositories(self):
        clock=[0]
        class Slow(Client):
            def query(self,document,variables,*,deadline):
                if variables['name']=='slow':
                    clock[0]=deadline
                    raise ClientError('deadline_exceeded')
                return super().query(document,variables,deadline=deadline)
        client=Slow();provider=PRProvider(client,[Repository('slow','owner/slow'),Repository('fast',REPO)],ROOT,helper=Helpers(),monotonic=lambda:clock[0])
        first=provider(2).data['repositories'];self.assertEqual(clock[0],1.75)
        self.assertTrue(first[0]['stale']);self.assertIsNone(first[1]['observed_at'])
        clock[0]=2
        second=provider(4).data['repositories'];self.assertEqual(clock[0],3.75)
        self.assertFalse(second[1]['stale']);self.assertEqual(len(second[1]['rows']),1)
        clock[0]=4
        third=provider(6).data['repositories'];self.assertTrue(third[1]['stale'])
        self.assertEqual(third[1]['observed_at'],second[1]['observed_at'])
        self.assertTrue(all(call[2] <= 3.75 for call in client.calls))

    def test_failed_slow_evidence_retains_stale_data_and_repository_denial(self):
        client,helper=Client(),Helpers();clock=[0]
        provider=PRProvider(client,[Repository('hub',REPO)],ROOT,helper=helper,monotonic=lambda:clock[0],clock=lambda:1000+clock[0])
        provider(100);helper.fail=True;clock[0]=120
        row=provider(200).data['repositories'][0]['rows'][0];self.assertTrue(row['stale']);self.assertEqual(row['budgets'][0]['used'],0);self.assertEqual(row['budgets'][0]['observed_at'],1000)
        client.failed=True;clock[0]=140;entry=provider(200).data['repositories'][0]
        self.assertTrue(entry['stale']);self.assertEqual(entry['observed_at'],1120);self.assertEqual(entry['rows'][0]['id'],REPO+'#1')

    def test_complete_pr_label_and_check_pagination(self):
        client=Client();client.next_page=[raw(2)];client.rows[0]['labels']=connection([{'name':'needs-external-review'}],'label-next')
        client.label_page=[{'name':'human-hold'}];provider=PRProvider(client,[Repository('hub',REPO)],ROOT,helper=Helpers())
        data=provider(time.monotonic()+5).data; self.assertEqual(len(data['repositories'][0]['rows']),2)
        self.assertEqual(data['repositories'][0]['rows'][0]['labels'],['needs-external-review','human-hold'])
        client=Client();client.rows[0]['commits']['nodes'][0]['commit']['statusCheckRollup']['contexts']['pageInfo']={'hasNextPage':True,'endCursor':'check-next'}
        client.check_page=[{'id':'second','name':'test','isRequired':True,'status':'COMPLETED','conclusion':'SUCCESS'}]
        row=PRProvider(client,[Repository('hub',REPO)],ROOT,helper=Helpers())(time.monotonic()+5).data['repositories'][0]['rows'][0]
        self.assertEqual(len(row['checks']),2)

    def test_explicit_merge_vs_closed_and_never_infer_from_absence(self):
        for terminal in ['MERGED','CLOSED']:
            client=Client();provider=PRProvider(client,[Repository('hub',REPO)],ROOT,helper=Helpers())
            provider(time.monotonic()+5);client.rows=[];client.terminal=terminal
            row=provider(time.monotonic()+5).data['repositories'][0]['rows'][0]
            self.assertEqual(row['lifecycle'],terminal);self.assertEqual(row['state'],'done' if terminal=='MERGED' else 'idle')

    def test_browser_precision_and_partial_sync_row(self):
        row=partial_row(REPO,'9007199254740993',merge_state='BEHIND',observed_at=1000)
        self.assertEqual(row['number'],'9007199254740993');self.assertIsNone(row['head']);self.assertIsNone(row['budgets'][0]['remaining'])
        self.assertEqual(exact(9007199254740993),'9007199254740993')
        parsed=json.loads(json.dumps(copy_json_tree(row))); self.assertEqual(parsed['number'],row['number'])
        node=subprocess.run(['node','-e', 'const R=require("./mergepath/cockpit/assets/pr_rows.js"); const row=JSON.parse(process.argv[1]); if(!R.validRow(row)||row.number!=="9007199254740993")process.exit(1)',json.dumps(row)],cwd=ROOT,timeout=5)
        self.assertEqual(node.returncode,0)

    def test_unknown_settings_and_pagination_refusal(self):
        self.assertIsNone(load_settings('/missing')['rounds_before_phase_4b'])
        client=Client();client.next_page=[raw()]
        entry=PRProvider(client,[Repository('hub',REPO)],ROOT,helper=Helpers())(time.monotonic()+5).data['repositories'][0]
        self.assertTrue(entry['stale']);self.assertIsNone(entry['observed_at'])

    def test_bridge_fixed_reads_jq_policy_and_refusal(self):
        class Reads:
            def get(self,path,*,deadline):
                if 'contents/' in path:return {'encoding':'base64','content':base64.b64encode(b'codex:\n  max_review_rounds: 20\n').decode()}
                return {'head':{'sha':HEAD}}
            def pages(self,path,*,deadline):return [{'id':1}]
        reader=HelperReader(Reads(),ROOT)
        deadline=time.monotonic()+5
        self.assertEqual(reader._api(['api',f'repos/{REPO}/pulls/1','--jq','.head.sha'],REPO,deadline).strip(),HEAD)
        self.assertIn('max_review_rounds',reader._api(['api',f'repos/{REPO}/contents/.github/review-policy.yml?ref='+HEAD,'-H','Accept: application/vnd.github.raw'],REPO,deadline))
        self.assertEqual(json.loads(reader._api(['api','--paginate',f'repos/{REPO}/pulls/1/reviews'],REPO,deadline)),[{'id':1}])
        for args in [['pr','review','1','--approve'],['api','-X','POST',f'repos/{REPO}/issues/1/comments'],['api','repos/other/repo/pulls/1'],['api','graphql','-f','query=mutation { x }']]:
            with self.assertRaises(ClientError):reader._api(args,REPO,deadline)
        cmd=['bash','-c', 'gh api "repos/$1/pulls/1" --jq "{head:.head.sha}"', 'fixture',REPO]
        self.assertEqual(reader._run(cmd,REPO,deadline),{'head':HEAD})
        self.assertIsNone(reader._run(['bash','-c','test "$GH_TOKEN" = cockpit-read-bridge && test -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" && printf null','fixture'],REPO,deadline))

    def test_actual_read_helpers_with_shared_fixture_client(self):
        class Reads:
            def get(self,path,*,deadline):
                if 'contents/' in path:return {'encoding':'base64','content':base64.b64encode((ROOT/'.github/review-policy.yml').read_bytes()).decode()}
                if '/pulls/' in path:return {'number':1,'head':{'sha':HEAD,'repo':{'id':1}},'base':{'sha':'b'*40,'ref':'main','repo':{'id':1,'default_branch':'main'}},'draft':False}
                if '/commits/' in path:return {'sha':HEAD,'commit':{'committer':{'date':'2026-10-03T00:00:00Z'}}}
                return {}
            def pages(self,path,*,deadline):return []
        data=HelperReader(Reads(),ROOT).read(REPO,'1',HEAD,time.monotonic()+15)
        self.assertIsNotNone(data['ledger']['data'],data)
        self.assertEqual(data['ledger']['data']['summary']['requests'],0)
        self.assertEqual(data['ledger']['data']['human_stops'],[])
        self.assertEqual(data['feedback']['data']['posted'],0)
        self.assertIsNotNone(data['coderabbit']['data'],data)
        self.assertIsNone(data['commits']['data']);self.assertIsNone(data['accounting']['data'])

    def test_actual_accounting_helpers_trusted_records_local_loops_and_exact_tokens(self):
        loop={'run_id':'fixture-unique','verdict':'CHANGES_REQUESTED','reviewer':'nathanpayne-codex',
              'tokens':{'total':9007199254740993,'input':None,'output':None,'cost_usd':1.25},'fail_closed':{'happened':False}}
        record={'schema':'p4b-accounting/v1','pr':1,'automation_state':'posted','final_reviewer':'nathanpayne-codex','loops':[loop]}
        body='<!-- p4b-accounting:v1\n'+json.dumps(record)+'\n-->'
        reviews=[{'user':{'login':'untrusted'},'body':body},{'user':{'login':'nathanpayne-codex'},'body':body}]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'.mergepath/phase-4b-loops';path.mkdir(parents=True)
            second={'run_id':'fixture-next','verdict':'APPROVED','tokens':{'total':None,'input':None,'output':None,'cost_usd':None}}
            (path/'owner-hub-pr1.jsonl').write_text(json.dumps({'loop':loop})+'\n'+json.dumps({'loop':second})+'\n')
            reader=HelperReader(None,ROOT,checkout_roots={REPO:directory})
            policy=(ROOT/'.github/review-policy.yml').read_text()
            data=reader._accounting(REPO,'1',reviews,time.monotonic()+10,policy=policy)
            self.assertEqual(data['totals']['tokens_total'],'9007199254740993');self.assertEqual(data['totals']['adapter_invocations'],2)
            self.assertEqual(data['totals']['reported_cost_usd'],1.25);self.assertEqual(data['reruns'],1)
            self.assertIn('1 of 2 observed loops',data['coverage'])
            conflict=copy.deepcopy(loop);conflict['tokens']['total']=2
            (path/'owner-hub-pr1.jsonl').write_text(json.dumps({'loop':conflict})+'\n')
            with self.assertRaises(ClientError):reader._accounting(REPO,'1',reviews,time.monotonic()+10,policy=policy)
            with self.assertRaises(ClientError):reader._accounting(REPO,'1',reviews,time.monotonic()+10)

    def test_consumer_code_rabbit_and_accounting_use_governing_target_config(self):
        policy=(ROOT/'.github/review-policy.yml').read_text().replace('  - nathanpayne-claude','  - consumer-reviewer').replace('  - nathanpayne-cursor\n','').replace('  - nathanpayne-codex\n','')
        cr='reviews:\n  auto_review:\n    drafts: true\n    base_branches:\n      - main\n'
        class Reads:
            def get(self,path,*,deadline):
                if 'contents/' in path:
                    content=cr if '.coderabbit.yml' in path else policy
                    return {'encoding':'base64','content':base64.b64encode(content.encode()).decode()}
                if '/pulls/' in path:return {'number':1,'head':{'sha':HEAD,'repo':{'id':1}},'base':{'sha':'b'*40,'ref':'main','repo':{'id':1,'default_branch':'main'}},'draft':True}
                if '/commits/' in path:return {'sha':HEAD,'commit':{'committer':{'date':'2026-10-03T00:00:00Z'}}}
                return {}
            def pages(self,path,*,deadline):return []
        reader=HelperReader(Reads(),ROOT)
        result=reader.read('owner/consumer','1',HEAD,time.monotonic()+15)
        self.assertEqual(result['coderabbit']['data']['status'],'no_review_yet')
        self.assertIsNone(result['coderabbit']['data']['skip_reason'])  # Hub drafts:false would misclassify this as skipped.
        loop={'verdict':'APPROVED','tokens':{'total':7,'cost_usd':None},'fail_closed':{'happened':False}}
        record={'schema':'p4b-accounting/v1','pr':1,'automation_state':'posted','loops':[loop]}
        body='<!-- p4b-accounting:v1\n'+json.dumps(record)+'\n-->'
        result=reader._accounting('owner/consumer','1',[{'user':{'login':'consumer-reviewer'},'body':body}],time.monotonic()+5,policy=policy)
        self.assertEqual(result['totals']['tokens_total'],7)
        with self.assertRaises(ClientError):reader._accounting('owner/consumer','1',[{'user':{'login':'nathanpayne-codex'},'body':body}],time.monotonic()+5,policy=policy)

    def test_same_head_base_advance_refuses_mixed_context_receipts(self):
        class Reads:
            def __init__(self):self.metadata_reads=0;self.paths=[]
            def get(self,path,*,deadline):
                self.paths.append(path)
                if 'contents/' in path:
                    return {'encoding':'base64','content':base64.b64encode((ROOT/'.github/review-policy.yml').read_bytes()).decode()}
                if '/pulls/' in path:
                    self.metadata_reads+=1;base='b'*40 if self.metadata_reads<=3 else 'c'*40
                    return {'number':1,'head':{'sha':HEAD,'repo':{'id':1}},'base':{'sha':base,'ref':'main','repo':{'id':1,'default_branch':'main'}},'draft':False}
                if '/commits/' in path:return {'sha':HEAD,'commit':{'committer':{'date':'2026-10-03T00:00:00Z'}}}
                return {}
            def pages(self,path,*,deadline):return []
        client=Reads();result=HelperReader(client,ROOT).read(REPO,'1',HEAD,time.monotonic()+15)
        self.assertTrue(all(receipt['data'] is None for receipt in result.values()),result)
        self.assertTrue(any('ref='+('b'*40) in path for path in client.paths))
        self.assertFalse(any('.coderabbit.yml' in path for path in client.paths))
        self.assertGreater(client.metadata_reads,3)

if __name__=='__main__':unittest.main()
