#!/usr/bin/env bash
# Offline execution of the two trusted Dependabot phases, with fake credentials.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import copy,json,os,pathlib,shutil,signal,subprocess,sys,tempfile,unittest
sys.dont_write_bytecode=True
ROOT=pathlib.Path(sys.argv[1]);HEAD='a'*40;BASE='b'*40;OTHER='c'*40
DRIVER=ROOT/'scripts/workflow/dependabot-approved-merge.sh'
GH=r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['STATE']);s=json.loads(p.read_text());args=sys.argv[1:]
role={'fake-reviewer':'reviewer','fake-author':'author','fake-workflow':'workflow'}.get(os.environ.get('GH_TOKEN'),'unknown')
s.setdefault('calls',[]).append({'role':role,'args':args})
def done(value=None,code=0):
 p.write_text(json.dumps(s))
 if value is not None: print(value if isinstance(value,str) else json.dumps(value))
 sys.exit(code)
if args[0]=='pr' and args[1]=='view':
 fields=args[args.index('--json')+1]
 if fields=='headRefOid': done(s['head'])
 if fields=='labels':
  s['label_reads']=s.get('label_reads',0)+1
  if s.get('hold_at_label')==s['label_reads']: s['labels']=['human-hold']
  done('\n'.join(s['labels']))
 if fields=='autoMergeRequest': done('true' if s.get('armed') else 'false')
 raise AssertionError(args)
if args[0]=='pr' and args[1]=='merge':
 op='disable' if '--disable-auto' in args else ('auto' if '--auto' in args else 'squash')
 s.setdefault('writes',[]).append({'operation':op,'role':role,'head':args[args.index('--match-head-commit')+1] if '--match-head-commit' in args else None})
 if op=='disable':
  assert role=='workflow';s['armed']=False;done()
 assert role=='author'
 if op=='auto' and s.get('auto_error'):
  print(s['auto_error'],file=sys.stderr);done(code=1)
 done()
assert args[0]=='api',args
method='GET';endpoint=None;fields={};i=1
while i<len(args):
 a=args[i];i+=1
 if a in ('-X','--method'): method=args[i];i+=1
 elif a in ('-f','-F'): k,v=args[i].split('=',1);fields[k]=v;i+=1
 elif a in ('-H','--header','--jq'): i+=1
 elif not a.startswith('-'): endpoint=a
if endpoint=='user':
 default={'login':'nathanpayne-codex' if role=='reviewer' else 'nathanjohnpayne','type':'User'}
 done(s.get(role+'_identity',default))
if '/contents/.github/review-policy.yml?ref=' in endpoint: done(s['policy'])
if endpoint=='repos/owner/repo/pulls/7':
 s['binding_reads']=s.get('binding_reads',0)+1
 if s.get('move_at_binding')==s['binding_reads']: s['head']='c'*40
 if s.get('base_at_binding')==s['binding_reads']: s['base']='c'*40
 done({'number':7,'state':s.get('pr_state','open'),'draft':s.get('draft',False),'user':{'login':s.get('opener','dependabot[bot]')},'head':{'sha':s['head'],'ref':'candidate; touch SHOULD_NOT_EXIST'},'base':{'sha':s['base'],'ref':'main','repo':{'full_name':s.get('base_repo','owner/repo')}}})
if '/commits?per_page=100' in endpoint:
 if s.get('unreadable_provenance'): done(code=1)
 done([{'sha':s['head'],'author':{'login':'attacker' if s.get('foreign') else 'dependabot[bot]'},'committer':{'login':'web-flow'},'commit':{'verification':{'verified':True}}}])
if endpoint=='repos/owner/repo/pulls/7/reviews' and method=='POST':
 assert role=='reviewer'
 review={'id':41,'state':'APPROVED','commit_id':fields['commit_id'],'user':{'login':'nathanpayne-codex','type':'User'},'submitted_at':'2026-10-15T00:00:00Z'}
 s.setdefault('writes',[]).append({'operation':'approve','role':role,'head':fields['commit_id']});s['reviews']=[review]
 done({} if s.get('bad_post') else review)
if endpoint=='repos/owner/repo/pulls/7/reviews/41':
 review=dict(s['reviews'][0])
 if s.get('bad_readback'): review['commit_id']='c'*40
 done(review)
if '/reviews?per_page=100' in endpoint:
 if s.get('unreadable_reviews'): done(code=1)
 done(s.get('reviews',[]))
raise AssertionError((method,endpoint,args))
'''
GATE=r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
sys.argv.pop(0)
p=Path(os.environ['STATE']);s=json.loads(p.read_text());name=Path(sys.argv[0]).name
role={'fake-reviewer':'reviewer','fake-author':'author','fake-workflow':'workflow'}.get(os.environ.get('GH_TOKEN'),'unknown')
s.setdefault('gates',[]).append({'name':name,'args':sys.argv[1:],'role':role})
if name=='required-head-checks.sh':
 assert sys.argv[-1]==s['head'];rc=s.get('ci_rc',0)
elif name=='review-feedback-accounting.sh':
 assert role=='workflow';rc=s.get('accounting_rc',0)
elif name=='codex-review-check.sh':
 assert role=='workflow' and sys.argv[1]=='--approval-readiness-only' and os.environ['SKIP_CI']=='0';rc=s.get('readiness_rc',0)
else:
 rc=s.get('clearance_rc',0)
 if s.get('hold_after_gate'): s['labels']=['human-hold']
p.write_text(json.dumps(s));sys.exit(rc)
'''
class Split(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.path=pathlib.Path(self.temp.name)
  (self.path/'scripts/workflow').mkdir(parents=True);(self.path/'scripts/lib').mkdir();(self.path/'bin').mkdir();(self.path/'.github').mkdir()
  shutil.copy(DRIVER,self.path/'scripts/workflow')
  shutil.copy(ROOT/'scripts/workflow/resolve_base_policy.sh',self.path/'scripts/workflow')
  for name in ('gh-api-array.sh','dependabot-commit-provenance.sh','reviewers-helpers.sh'):shutil.copy(ROOT/'scripts/lib'/name,self.path/'scripts/lib')
  for name in ('required-head-checks.sh','review-feedback-accounting.sh','codex-review-check.sh','merge-clearance-gate.sh'):
   q=self.path/'scripts'/name;q.write_text('#!/usr/bin/env bash\nexec python3 - "$0" "$@" <<\'PY\'\n'+GATE+'\nPY\n');q.chmod(0o755)
  q=self.path/'bin/gh';q.write_text(GH);q.chmod(0o755)
  self.policy='author_identity: nathanjohnpayne\navailable_reviewers:\n  - nathanpayne-codex\n  - nathanpayne-claude\n'
  self.state={'head':HEAD,'base':BASE,'labels':[],'policy':self.policy,'calls':[],'writes':[]}
  self.env={k:v for k,v in os.environ.items() if k in ('PATH','LANG','LC_ALL','LC_CTYPE','TZ')}
  self.env.update(HOME=str(self.path),PATH=str(self.path/'bin')+':'+self.env['PATH'],STATE=str(self.path/'state.json'),WORKFLOW_GH_TOKEN='fake-workflow',GITHUB_REPOSITORY='owner/repo',PR_NUMBER='7',PR_HEAD_SHA=HEAD,PR_BASE_SHA=BASE,DEFAULT_BRANCH='main',UPDATE_TYPE='version-update:semver-patch',DEPENDENCY_GROUP='',GITHUB_OUTPUT=str(self.path/'output'),TEST_CHECK_WAIT_SECONDS='0',TEST_CHECK_POLL_SECONDS='0')
 def run_phase(self,phase):
  (self.path/'state.json').write_text(json.dumps(self.state));(self.path/'.github/review-policy.yml').write_text(self.state['policy']);self.env['GH_TOKEN']='fake-reviewer' if phase=='approve' else 'fake-author'
  p=subprocess.Popen(['bash','scripts/workflow/dependabot-approved-merge.sh',phase],cwd=self.path,env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  try:stdout,stderr=p.communicate(timeout=12)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.communicate();raise
  self.state=json.loads((self.path/'state.json').read_text());return p.returncode,stdout+stderr
 def approved(self):
  code,out=self.run_phase('approve');self.assertEqual(code,0,out);self.state['writes']=[]
 def test_positive_split_rederives_actual_approval_and_only_transports_tuple(self):
  self.approved();output=(self.path/'output').read_text();self.assertEqual({x.split('=')[0] for x in output.splitlines()},{'repo','pr','head','base','base_ref'});self.assertNotIn('fake-',output)
  code,out=self.run_phase('merge');self.assertEqual(code,0,out);self.assertEqual(self.state['writes'],[{'operation':'auto','role':'author','head':HEAD}]);self.assertFalse((self.path/'SHOULD_NOT_EXIST').exists())
 def test_inert_handoff_without_real_approval_never_merges(self):
  code,_=self.run_phase('merge');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
 def test_stale_or_nonuser_or_dismissed_approval_cannot_authorize(self):
  self.approved();good=copy.deepcopy(self.state['reviews'])
  for change in ('stale','app','dismissed','unregistered'):
   with self.subTest(change=change):
    self.state['reviews']=copy.deepcopy(good)
    if change=='stale':self.state['reviews'][0]['commit_id']=OTHER
    elif change=='app':self.state['reviews'][0]['user']['type']='Bot'
    elif change=='unregistered':self.state['reviews'][0]['user']['login']='not-registered'
    else:self.state['reviews'].append(dict(good[0],id=42,state='DISMISSED',submitted_at='2026-10-15T00:01:00Z'))
    code,_=self.run_phase('merge');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
 def test_bad_approval_response_or_readback_never_exports_authorization(self):
  for name in ('bad_post','bad_readback'):
   with self.subTest(name=name):
    self.state[name]=True;code,_=self.run_phase('approve');self.assertNotEqual(code,0);self.assertFalse((self.path/'output').exists());self.assertEqual(len(self.state['writes']),1);self.state[name]=False;self.state['writes']=[]
 def test_actor_and_governing_identity_fail_closed(self):
  for identity,policy in [({'login':'nathanjohnpayne','type':'User'},self.policy),({'login':'nathanpayne-codex','type':'Bot'},self.policy),({'login':'','type':'User'},self.policy)]:
   with self.subTest(identity=identity,policy=policy):
    self.state.update(reviewer_identity=identity,policy=policy);code,_=self.run_phase('approve');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
 def test_missing_and_empty_author_keep_existing_dependabot_default(self):
  for author_line in ('', 'author_identity:\n'):
   with self.subTest(author_line=author_line):
    self.state.update(policy=author_line+'available_reviewers:\n  - nathanpayne-codex\n',writes=[])
    self.approved();code,out=self.run_phase('merge');self.assertEqual(code,0,out);self.assertEqual([w['operation'] for w in self.state['writes']],['auto'])
 def test_custom_policy_author_is_exact_and_unreadable_lists_fail_closed(self):
  self.state['policy']=self.policy.replace('author_identity: nathanjohnpayne', 'author_identity: "custom-owner" # governing author')
  self.approved();code,_=self.run_phase('merge');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
  self.state['author_identity']={'login':'custom-owner','type':'User'};code,out=self.run_phase('merge');self.assertEqual(code,0,out)
  self.state.update(policy=self.policy+'non_reviewer_identities: [service-user]\n',writes=[])
  code,_=self.run_phase('approve');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
 def test_wrong_author_or_same_reviewer_identity_cannot_merge(self):
  self.approved()
  for login in ('nathanpayne-codex','other-user',''):
   self.state['author_identity']={'login':login,'type':'User'};code,_=self.run_phase('merge');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
 def test_head_base_opener_and_ci_changes_do_not_merge(self):
  self.approved();original=copy.deepcopy(self.state)
  for field,value in [('head',OTHER),('base',OTHER),('opener','attacker'),('ci_rc',1),('clearance_rc',1),('unreadable_reviews',True)]:
   with self.subTest(field=field):
    self.state=copy.deepcopy(original);self.state[field]=value;code,_=self.run_phase('merge');self.assertNotEqual(code,0);self.assertFalse(self.state['writes'])
 def test_hold_before_approval_and_after_gate_stops_writers(self):
  self.state['labels']=['human-hold'];code,_=self.run_phase('approve');self.assertEqual(code,0);self.assertFalse(self.state['writes'])
  self.state['labels']=[];self.approved();self.state['hold_after_gate']=True;code,_=self.run_phase('merge');self.assertEqual(code,0);self.assertFalse(self.state['writes'])
 def test_hold_arriving_after_final_approval_reads_stops_each_writer(self):
  self.state['hold_at_label']=3;code,out=self.run_phase('approve');self.assertEqual(code,0,out);self.assertFalse(self.state['writes'])
  self.state.update(labels=[],hold_at_label=None,label_reads=0);self.approved();self.state.update(label_reads=0,hold_at_label=3)
  code,out=self.run_phase('merge');self.assertEqual(code,0,out);self.assertFalse(self.state['writes'])
 def test_foreign_provenance_withdraws_arm_using_workflow_identity(self):
  self.approved();self.state.update(foreign=True,armed=True);code,_=self.run_phase('merge');self.assertEqual(code,0);self.assertEqual(self.state['writes'],[{'operation':'disable','role':'workflow','head':None}])
 def test_major_dev_group_is_approved_only(self):
  self.env.update(UPDATE_TYPE='version-update:semver-major',DEPENDENCY_GROUP='dev-dependencies');self.approved();code,out=self.run_phase('merge');self.assertEqual(code,0,out);self.assertFalse(self.state['writes'])
 def test_known_unavailability_replays_all_immediate_squash_gates(self):
  self.approved();self.state['auto_error']='Auto-merge is not available';code,out=self.run_phase('merge');self.assertEqual(code,0,out);self.assertEqual([w['operation'] for w in self.state['writes']],['auto','squash']);self.assertIn('codex-review-check.sh',[x['name'] for x in self.state['gates']]);self.assertIn('review-feedback-accounting.sh',[x['name'] for x in self.state['gates']])
 def test_unknown_auto_error_and_fallback_gate_failures_refuse_squash(self):
  self.approved();original=copy.deepcopy(self.state)
  for field,value in [('auto_error','Network failure'),('auto_error','Permission denied (enablePullRequestAutoMerge)'),('accounting_rc',1),('readiness_rc',1)]:
   with self.subTest(field=field):
    self.state=copy.deepcopy(original);self.state['auto_error']='Auto-merge is not available';self.state[field]=value;code,_=self.run_phase('merge');self.assertNotEqual(code,0);self.assertEqual([x['operation'] for x in self.state['writes']],['auto'])
 def test_workflow_separates_environment_secrets_and_only_uses_trusted_source(self):
  command=['ruby','-ryaml','-rjson','-e','puts JSON.dump(YAML.load_file(ARGV[0]))',str(ROOT/'.github/workflows/dependabot-auto-merge.yml')];workflow=json.loads(subprocess.check_output(command,text=True));jobs=workflow['jobs']
  self.assertEqual(jobs['approve']['environment'],'reviewer-maintenance');self.assertEqual(jobs['auto-merge']['environment'],'merge-queue-policy')
  for job,forbidden in [('approve','AUTHOR_MERGE_TOKEN'),('auto-merge','REVIEWER_ASSIGNMENT_TOKEN')]:
   self.assertNotIn(forbidden,json.dumps(jobs[job]));self.assertNotIn('REVIEW_AUTOMATION',json.dumps(jobs[job]));self.assertIn("github.ref == 'refs/heads/main'",jobs[job]['if'])
   for step in jobs[job]['steps']:
    if 'actions/checkout@' in step.get('uses',''):self.assertEqual(step['with'],{'ref':'${{ github.sha }}','persist-credentials':False})
  self.assertEqual(set(jobs['approve']['outputs']),{'repo','pr','head','base','base_ref'})
unittest.main(argv=['dependabot-split'],verbosity=2)
PY
