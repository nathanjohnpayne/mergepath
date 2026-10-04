"""Hermetic actual-provider/worker boundaries. Expected <25s; bound60s."""

import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mergepath.cockpit.fleet import FleetProvider
from mergepath.cockpit.github import ClientError
from mergepath.cockpit.inventory import HUB, Repository
from mergepath.cockpit.scheduler import Sample
from mergepath.cockpit.sync import SyncError, SyncProvider, resolve_git_identity
from mergepath.cockpit.sync_worker import cached_author

INVENTORY = (Repository("mergepath", HUB, True), Repository("one", "owner/one"), Repository("two", "owner/two"))
IDENTITY = {"name": "Verified Fixture Author", "email": "fixture@example.invalid", "signing": False}


def record(entry, sha, ahead=False, old=False):
    return {"schema_version": 1, "name": entry.name, "repo": entry.repo, "visibility": "private",
            "baseline": "origin/main@" + "b" * 40,
            "baseline_info": {"ref": "origin/main", "sha": "b" * 40, "kind": "cache-clone", "refreshed": True, "dirty": False, "warnings": []},
            "hub_sha": sha, "status": "ahead" if ahead else "drift",
            "paths": [{"path": "README.md", "class": "canonical", "direction": "consumer ahead of hub" if ahead else "hub ahead",
                       "comparison": "different bytes", "override_reason": None, "provenance": None}],
            "open_sync_prs": [{"number": 88, "branch": "mergepath-sync/old", "state": "BEHIND", "lifecycle_state": "OPEN", "draft": False}] if old else [],
            "error": None, "audited_at": "2026-10-03T20:00:00Z"}


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.thread_errors = []
        self.thread_hook = mock.patch.object(threading, 'excepthook', side_effect=lambda args: self.thread_errors.append(args.exc_type.__name__))
        self.thread_hook.start()
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "hub"
        (self.root / "scripts").mkdir(parents=True)
        self.records = self.base / "records.json"
        self.calls = self.base / "calls.jsonl"
        self.audits = self.base / "audits.jsonl"
        self.mode = self.base / "mode"
        self.mode.write_text("ok")
        self.cache = self.base / "cache-mode"
        self.cache.write_text("ok")
        self.providers = []
        self.gh = self.base / "gh"
        self.gh.write_text('#!/bin/sh\nexit 99\n')
        self.gh.chmod(0o700)
        canonical = (Path(__file__).resolve().parents[1] / 'scripts/op-preflight.sh').read_text()
        cleanup = canonical.split("DEPLOY_CLEAR_STMT='", 1)[1].split("'\n", 1)[0] + '; unset CF_API_TOKEN'
        preflight = f'''#!/usr/bin/env bash
case "$(cat '{self.cache}')" in
 fail) exit 1;; empty) echo 'export OP_PREFLIGHT_AUTHOR_PAT=';; reviewer) echo 'export OP_PREFLIGHT_REVIEWER_PAT=reviewer_secret';;
 malformed) echo 'export OP_PREFLIGHT_AUTHOR_PAT=$(touch /never-execute)' ;;
 canonical) echo 'export OP_PREFLIGHT_AUTHOR_PAT=github_pat_fixture_AUTHOR_secret'; echo 'export OP_PREFLIGHT_REVIEWER_PAT=reviewer_secret'; echo 'export GH_TOKEN=reviewer_secret'; printf '%s\\n' '{cleanup}'; echo 'export OP_PREFLIGHT_DONE=1'; echo 'export OP_PREFLIGHT_AGENT=codex'; echo 'export OP_PREFLIGHT_MODE=review';;
 *) echo 'export OP_PREFLIGHT_AUTHOR_PAT=github_pat_fixture_AUTHOR_secret'; echo 'export OP_PREFLIGHT_REVIEWER_PAT=reviewer_secret';;
esac
'''
        (self.root / "scripts/op-preflight.sh").write_text(preflight)
        engine = f'''#!/usr/bin/env bash
exec '{sys.executable}' -B - "$@" <<'PY'
import json,os,sys,time
from pathlib import Path
args=sys.argv[1:]
mode=Path({str(self.mode)!r}).read_text()
if '--dry-run' in args:
 print('Proposed manifest paths; remote overrides require audit');sys.exit(0)
if '--audit' in args:
 rows=json.loads(Path({str(self.records)!r}).read_text())
 if '--repos' in args: rows=[r for r in rows if r['repo']==args[args.index('--repos')+1]]
 with open({str(self.audits)!r},'a') as f: f.write(json.dumps({{'args':args,'repos':[r['repo'] for r in rows]}})+'\\n')
 if mode=='audit-missing': rows=[]
 if mode=='audit-extra': rows=json.loads(Path({str(self.records)!r}).read_text())
 if mode=='audit-duplicate': rows=rows+rows
 if mode=='audit-unexpected': rows[0]['repo']='owner/unexpected'
 if mode=='audit-malformed': print('{{');sys.exit(1)
 for r in rows: print(json.dumps(r))
 sys.exit(0 if mode=='audit-exit' else 2 if mode=='audit-failure' else 1)
with open({str(self.calls)!r},'a') as f: f.write(json.dumps({{'args':args,'env':{{k:v for k,v in os.environ.items() if k in ('GH_TOKEN','OP_PREFLIGHT_AUTHOR_PAT','OP_PREFLIGHT_REVIEWER_PAT','MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK','GITHUB_TOKEN','MERGEPATH_ROOT_OVERRIDE','MERGEPATH_SYNC_AUTHORING_AGENT')}}}})+'\\n')
repo=args[args.index('--repos')+1]
print('author='+os.environ.get('GH_TOKEN',''),flush=True)
if mode=='identity':
 import subprocess,tempfile
 directory=Path(tempfile.mkdtemp(dir=os.environ['TMPDIR']))
 subprocess.run(['git','init','-qb','main',str(directory)],check=True)
 subprocess.run(['git','-C',str(directory),'config','user.name','Wrong clone identity'],check=True)
 subprocess.run(['git','-C',str(directory),'config','user.email','wrong@example.invalid'],check=True)
 (directory/'file').write_text('fixture')
 subprocess.run(['git','-C',str(directory),'add','file'],check=True)
 subprocess.run(['git','-C',str(directory),'commit','-qm','fixture'],check=True)
 value=subprocess.check_output(['git','-C',str(directory),'log','-1','--format=%an|%ae|%cn|%ce'],text=True).strip()
 Path({str(self.base / 'identity.txt')!r}).write_text(value)
if mode=='delay':time.sleep(2)
if mode=='hang':
 import subprocess
 child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'])
 Path({str(self.base / 'child.pid')!r}).write_text(str(child.pid))
 time.sleep(60)
if mode=='flood':print('x'*400000);sys.exit(0)
line_mode=mode.removeprefix('second-') if repo=='owner/two' or not mode.startswith('second-') else ''
if line_mode.startswith('line-'):
 _,length,stream,ending=line_mode.split('-')
 if ending=='newline':
  output=sys.stdout if stream=='stdout' else sys.stderr
  output.write('x'*int(length)+'\\n');output.flush();time.sleep(.03)
for stage in ('fetch','diff','branch','commit','PR'):
 print('@@cockpit-sync\\t'+json.dumps({{'kind':'stage','repo':repo,'value':stage}}),flush=True)
if mode=='fail' or mode=='partial' and repo=='owner/two':sys.exit(1)
print('@@cockpit-sync\\t'+json.dumps({{'kind':'result','repo':repo,'value':'https://github.com/'+repo+'/pull/99'}}),flush=True)
if line_mode.startswith('line-') and ending=='eof':
 time.sleep(.03)
 output=sys.stdout if stream=='stdout' else sys.stderr
 output.write('x'*int(length));output.flush()
PY
'''
        (self.root / "scripts/sync-to-downstream.sh").write_text(engine)
        (self.root / ".mergepath-sync.yml").write_text("fixture manifest\n")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.sha = self.git("rev-parse", "HEAD").strip()
        self.git("remote", "add", "origin", f"https://github.com/{HUB}.git")
        self.git("update-ref", "refs/remotes/origin/main", self.sha)
        self.save([record(e, self.sha) for e in INVENTORY[1:]])

    def git(self, *args):
        home=self.base/'fixture-home';home.mkdir(mode=0o700,exist_ok=True)
        templates=self.base/'fixture-templates';templates.mkdir(mode=0o700,exist_ok=True)
        # Fixture setup must never reach machine signing, hooks or ambient Git
        # identity/config overrides, even when the operator enables signing.
        env={'PATH':'/usr/bin:/bin','HOME':str(home),'LC_ALL':'C','GIT_CONFIG_NOSYSTEM':'1',
             'GIT_CONFIG_SYSTEM':os.devnull,'GIT_CONFIG_GLOBAL':os.devnull,'GIT_TERMINAL_PROMPT':'0',
             'GIT_ASKPASS':'/usr/bin/false','GIT_AUTHOR_NAME':'Fixture Setup','GIT_AUTHOR_EMAIL':'fixture@example.invalid',
             'GIT_COMMITTER_NAME':'Fixture Setup','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
        settings=[('user.name','Fixture Setup'),('user.email','fixture@example.invalid'),('commit.gpgsign','false'),
                  ('core.hooksPath',os.devnull),('core.fsmonitor','false'),('init.templateDir',str(templates))]
        env['GIT_CONFIG_COUNT']=str(len(settings))
        for index,(key,value) in enumerate(settings):env[f'GIT_CONFIG_KEY_{index}'],env[f'GIT_CONFIG_VALUE_{index}']=key,value
        return subprocess.check_output(["/usr/bin/git", "-C", str(self.root), *args], env=env,stderr=subprocess.DEVNULL, text=True)

    def save(self, records):
        self.records.write_text(json.dumps(records))

    def fetch(self, deadline):
        records = json.loads(self.records.read_text())
        return Sample({"schema": "cockpit-fleet/v1", "hub_repo": HUB,
                       "repositories": [{"repo": r["repo"], "attempt": r, "stale": r["status"] == "fetch-error"} for r in records]})

    def provider(self, **kw):
        p = SyncProvider(INVENTORY, self.root, self.fetch, cache_dir=self.base,
                         tools={"bash": "/bin/bash", "git": "/usr/bin/git", "gh": str(self.gh), "python": sys.executable},
                         lock_parent=self.base, git_identity=kw.pop("git_identity", IDENTITY), **kw)
        self.providers.append(p)
        return p

    def wait(self, p, phase=None, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            state = p.snapshot("session")
            if state["phase"] not in ("previewing", "running") and (phase is None or state["phase"] == phase):
                return state
            time.sleep(.01)
        self.fail("bounded fixture did not settle: " + str(p.snapshot("session")))

    def preview(self, p, repos=None):
        p.preview("session", {"repos": repos or ["owner/one"]})
        state = self.wait(p)
        self.assertEqual(state["phase"], "preview", state)
        return state["preview"]

    def payload(self, preview, **overrides):
        return {"preview_id": preview["preview_id"], "hub_sha": preview["hub_sha"],
                "choices": {t["repo"]: t["default_choice"] for t in preview["targets"]}, "ack_ahead": False, **overrides}

    def called(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def tearDown(self):
        try:
            for p in self.providers:
                p.close()
            self.assertEqual(self.thread_errors, [], 'Background provider exceptions must fail the test')
        finally:
            self.thread_hook.stop()
            self.temp.cleanup()

    def test_actual_worker_sequential_and_secret_boundary(self):
        p = self.provider()
        preview = self.preview(p, ["owner/two", "owner/one"])
        self.assertEqual([t["repo"] for t in preview["targets"]], ["owner/one", "owner/two"])
        with mock.patch.dict(os.environ, {"GH_TOKEN": "ambient", "GITHUB_TOKEN": "ambient",
                "OP_PREFLIGHT_AUTHOR_PAT": "ambient", "OP_PREFLIGHT_REVIEWER_PAT": "ambient",
                "MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK": "1", "MERGEPATH_ROOT_OVERRIDE": "/bad"}):
            p.confirm("session", self.payload(preview))
            state = self.wait(p)
        self.assertEqual(state["run"]["outcome"], "success", state)
        self.assertEqual([c["args"][c["args"].index("--repos") + 1] for c in self.called()], ["owner/one", "owner/two"])
        for call in self.called():
            self.assertEqual(call["env"], {"GH_TOKEN": "github_pat_fixture_AUTHOR_secret", "OP_PREFLIGHT_AUTHOR_PAT": "github_pat_fixture_AUTHOR_secret", "MERGEPATH_SYNC_AUTHORING_AGENT": "codex"})
            self.assertIn(self.sha, call["args"])
            self.assertNotIn("--recreate-existing", call["args"])
        exposed = json.dumps(state)
        self.assertNotIn("fixture_AUTHOR_secret", exposed)
        self.assertNotIn("reviewer_secret", exposed)
        self.assertNotIn(str(self.root), exposed)
        self.assertEqual(p.snapshot("other")["phase"], "idle")
        journal = (self.base / "cockpit-sync.jsonl").read_text()
        self.assertNotIn("fixture_AUTHOR_secret", journal)
        self.assertNotIn(preview["preview_id"], journal)
        self.assertEqual([json.loads(line)["event"] for line in journal.splitlines()], ["started", "finished"])
        with self.assertRaisesRegex(SyncError, "consumed"):
            p.confirm("session", self.payload(preview))

    def test_canonical_exports_cleanup_is_inert_in_actual_worker(self):
        self.cache.write_text('canonical')
        p=self.provider();preview=self.preview(p)
        p.confirm('session',self.payload(preview));state=self.wait(p)
        self.assertEqual(state['run']['outcome'],'success',state)
        self.assertEqual(self.called()[0]['env']['GH_TOKEN'],'github_pat_fixture_AUTHOR_secret')
        marker=self.base/'must-not-execute'
        output=(f'export OP_PREFLIGHT_AUTHOR_PAT=valid_token\n'
                f'touch {marker}\nexport GH_TOKEN=reviewer\nunterminated "\n').encode()
        self.assertEqual(cached_author(output),'valid_token')
        self.assertFalse(marker.exists())
        for assignment in ('export OP_PREFLIGHT_AUTHOR_PAT =token', 'export OP_PREFLIGHT_AUTHOR_PAT',
                           'export OP_PREFLIGHT_AUTHOR_PAT=ok; touch /never-execute',
                           'export OP_PREFLIGHT_AUTHOR_PAT=$(evil)'):
            with self.subTest(assignment=assignment),self.assertRaises(SyncError):
                cached_author(('export OP_PREFLIGHT_AUTHOR_PAT=valid_token\n'+assignment).encode())

    def test_each_selected_target_has_only_its_own_revalidation_audit(self):
        p=self.provider();preview=self.preview(p,['owner/two','owner/one'])
        p.confirm('session',self.payload(preview));state=self.wait(p)
        self.assertEqual(state['run']['outcome'],'success',state)
        audits=[json.loads(line) for line in self.audits.read_text().splitlines()]
        self.assertEqual([a['repos'] for a in audits],[['owner/one'],['owner/two']])
        self.assertEqual([a['args'] for a in audits],
                         [['--audit','--json','--repos',repo] for repo in ('owner/one','owner/two')])
        self.assertEqual([c['args'][c['args'].index('--repos')+1] for c in self.called()],['owner/one','owner/two'])

    def test_target_audit_rejects_missing_extra_duplicate_unexpected_malformed_and_exit(self):
        p=self.provider()
        for mode in ('missing','extra','duplicate','unexpected','malformed','exit','failure'):
            with self.subTest(mode=mode):
                preview=self.preview(p);self.mode.write_text('audit-'+mode)
                p.confirm('session',self.payload(preview));state=self.wait(p)
                self.assertEqual(state['run']['outcome'],'refused',state)
                self.assertFalse(self.called())
                self.mode.write_text('ok')

    def test_held_fleet_lock_reports_busy_without_audit_retry(self):
        p=self.provider()
        fleet=FleetProvider(INVENTORY,self.root,'synthetic',cache_parent=self.base,
                            utilities={k:p.tools[k] for k in ('bash','git','gh')})
        try:
            p.fetch=fleet.fetch
            with fleet._lock, mock.patch.object(fleet,'_check_cache') as checked:
                p.preview('session',{'repos':['owner/one']});state=self.wait(p)
                self.assertEqual(state['error'],'audit_busy',state)
                checked.assert_not_called()
                self.assertFalse(self.called())
        finally:
            fleet.close()
        for reason in ('upstream_timeout','invalid_upstream_json'):
            with self.subTest(reason=reason):
                p.fetch=mock.Mock(side_effect=ClientError(reason))
                p.preview('session',{'repos':['owner/one']});state=self.wait(p)
                self.assertEqual(state['error'],'audit_unavailable',state)
                p.fetch.assert_called_once()

    def test_dirty_branch_origin_and_inventory_refusals(self):
        for mutate, reason in ((lambda: (self.root / "untracked").write_text("x"), "hub_dirty"),):
            mutate(); p = self.provider(); p.preview("session", {"repos": ["owner/one"]})
            self.assertEqual(self.wait(p)["error"], reason)
        (self.root / "untracked").unlink()
        self.git("checkout", "-qb", "feature")
        p = self.provider();p.preview("session", {"repos": ["owner/one"]})
        self.assertEqual(self.wait(p)["error"], "hub_not_main")
        self.git("checkout", "-q", "main")
        self.git("commit", "--allow-empty", "-qm", "unmerged")
        p = self.provider();p.preview("session", {"repos": ["owner/one"]})
        self.assertEqual(self.wait(p)["error"], "hub_not_origin_main")
        for repos in ([HUB], ["owner/one", "owner/one"], ["arbitrary/repo"], []):
            with self.assertRaises(SyncError):p.preview("session", {"repos": repos})
        self.assertFalse(self.called())

    def test_ahead_existing_choices_cancel_expiry(self):
        self.save([record(INVENTORY[1], self.sha, ahead=True, old=True), record(INVENTORY[2], self.sha)])
        p = self.provider();preview = self.preview(p)
        with self.assertRaisesRegex(SyncError, "all_skipped"):p.confirm("session", self.payload(preview))
        chosen = self.payload(preview, choices={"owner/one": "recreate"})
        with self.assertRaisesRegex(SyncError, "ahead_ack_required"):p.confirm("session", chosen)
        with self.assertRaises(SyncError):p.confirm("other", chosen)
        p.confirm("session", {**chosen, "ack_ahead": True})
        self.assertEqual(self.wait(p)["phase"], "done")
        call = self.called()[0]["args"]
        self.assertRegex(call[call.index("--fresh-branch") + 1], r"^[0-9a-f]{32}$")
        self.assertNotIn("--recreate-existing", call)
        preview = self.preview(p)
        p.cancel("session", {"preview_id": preview["preview_id"]})
        with self.assertRaises(SyncError):p.confirm("session", self.payload(preview))
        preview = self.preview(p)
        p._preview["deadline"] = time.monotonic() - 1
        self.assertFalse(p.snapshot("session")["preview"]["can_confirm"])
        with self.assertRaisesRegex(SyncError, "expired"):p.confirm("session", self.payload(preview))

    def test_cache_failure_no_engine_no_ambient_fallback(self):
        p = self.provider()
        for mode in ("fail", "empty", "reviewer", "malformed"):
            self.cache.write_text(mode);preview = self.preview(p)
            p.confirm("session", self.payload(preview));state = self.wait(p)
            self.assertEqual(state["run"]["outcome"], "refused", state)
            self.assertIn("cached_author_required", json.dumps(state))
        self.assertFalse(self.called())

    def test_consumer_and_hub_revalidation_before_dispatch(self):
        p = self.provider();preview = self.preview(p)
        rows = json.loads(self.records.read_text());rows[0]["open_sync_prs"] = record(INVENTORY[1], self.sha, old=True)["open_sync_prs"];self.save(rows)
        p.confirm("session", self.payload(preview));state = self.wait(p)
        self.assertEqual(state["run"]["outcome"], "refused")
        self.assertFalse(self.called())
        preview = self.preview(p)
        (self.root / "new").write_text("changed")
        p.confirm("session", self.payload(preview, choices={"owner/one": "recreate"}));state = self.wait(p)
        self.assertEqual(state["run"]["outcome"], "refused")
        self.assertFalse(self.called())

    def test_cross_instance_os_lock_and_shutdown_descendant(self):
        a,b = self.provider(), self.provider()
        pa,pb = self.preview(a),self.preview(b)
        self.mode.write_text("hang")
        a.confirm("session", self.payload(pa))
        with self.assertRaisesRegex(SyncError, "busy"):b.confirm("session", self.payload(pb))
        end=time.monotonic()+3
        while not (self.base / "child.pid").exists() and time.monotonic()<end:time.sleep(.01)
        self.assertTrue((self.base / "child.pid").exists())
        child=int((self.base / "child.pid").read_text())
        # Simulate loss of the server's descriptor: the real worker still holds
        # its inherited OS lock, rather than relying on an in-process flag.
        os.close(a._lock_fd);a._lock_fd=None
        with self.assertRaisesRegex(SyncError, "busy"):b.confirm("session", self.payload(pb))
        real_killpg, worker_pid = os.killpg, a._process.pid
        first_signal = []
        def deny_initial_signal(pid, sig):
            if pid == worker_pid and sig == signal.SIGKILL and not first_signal:
                first_signal.append(pid)
                raise PermissionError(1, 'fixture denied initial shutdown signal')
            return real_killpg(pid, sig)
        with mock.patch('os.killpg', side_effect=deny_initial_signal):
            a.close()
        self.assertEqual(first_signal, [worker_pid])
        self.assertEqual(a.snapshot('session')['phase'], 'error')
        self.assertNotEqual(a.snapshot('session')['run']['outcome'], 'running')
        self.assertIsNone(a._lock_fd)
        # killpg closes the entire inherited worker group, even a pipe-holding grandchild.
        time.sleep(.05)
        ps=subprocess.run(["/bin/ps","-p",str(child),"-o","stat="],capture_output=True,text=True)
        self.assertTrue(ps.returncode != 0 or ps.stdout.strip().startswith("Z"), ps.stdout)
        self.mode.write_text("ok")
        b.confirm("session",self.payload(pb));self.assertEqual(self.wait(b)["phase"],"done")

    def test_partial_and_output_cap_remain_truthful(self):
        p=self.provider();self.mode.write_text("partial")
        preview=self.preview(p,["owner/one","owner/two"]);p.confirm("session",self.payload(preview))
        state=self.wait(p);self.assertEqual(state["run"]["outcome"],"partial")
        self.assertEqual(len(state["run"]["results"]),1)
        self.mode.write_text("flood");preview=self.preview(p);p.confirm("session",self.payload(preview))
        state=self.wait(p);self.assertNotEqual(state["run"]["outcome"],"success")
        self.assertLess(len(json.dumps(state)),300000)

    def test_cleanup_signal_failure_requires_group_proof_and_always_finalizes(self):
        real_killpg = os.killpg
        for deny_probe in (False, True):
            p, other = self.provider(), self.provider()
            preview, other_preview = self.preview(p), self.preview(other)

            def deny_signal(pid, sig):
                process = p._process
                if process is not None and pid == process.pid and process.poll() == 0:
                    if sig == signal.SIGKILL or deny_probe:
                        raise PermissionError(1, 'fixture denied group signal')
                return real_killpg(pid, sig)

            with mock.patch('os.killpg', side_effect=deny_signal):
                p.confirm('session', self.payload(preview));state = self.wait(p)
                self.assertIn('finished_at', state['run'])
                self.assertEqual(len(state['run']['results']), 1)
                self.assertEqual(json.loads((self.base/'cockpit-sync.jsonl').read_text().splitlines()[-1])['event'], 'finished')
                if deny_probe:
                    self.assertEqual(state['error'], 'cleanup_incomplete')
                    self.assertEqual(state['run']['outcome'], 'partial')
                    self.assertIsNotNone(p._lock_fd)
                    self.assertTrue(all(pipe.closed for pipe in (p._process.stdin, p._process.stdout)))
                    with self.assertRaisesRegex(SyncError, 'cleanup_incomplete'):
                        p.preview('session', {'repos':['owner/one']})
                    with self.assertRaisesRegex(SyncError, 'sync_busy'):
                        other.confirm('session', self.payload(other_preview))
                    with self.assertRaisesRegex(SyncError, 'cleanup_incomplete'):
                        p.close()
                    self.assertTrue(p.workspace.exists())
                    self.assertFalse(p._thread.is_alive())
                else:
                    self.assertEqual(state['run']['outcome'], 'success')
                    self.assertIsNone(p._lock_fd)
            p.close()
            other.confirm('session', self.payload(other_preview))
            self.assertEqual(self.wait(other)['phase'], 'done')

    def test_actual_worker_line_boundaries_for_both_streams_and_eof(self):
        p=self.provider()
        for stream in ('stdout','stderr'):
            for ending in ('newline','eof'):
                for length in (4096,4097):
                    with self.subTest(stream=stream,ending=ending,length=length):
                        self.mode.write_text(f'line-{length}-{stream}-{ending}')
                        preview=self.preview(p);p.confirm('session',self.payload(preview));state=self.wait(p)
                        if length==4096:
                            self.assertEqual(state['run']['outcome'],'success',state)
                            self.assertTrue(any(e.get('text')=='x'*length for e in state['run']['events']))
                        else:
                            self.assertNotEqual(state['run']['outcome'],'success',state)
                            self.assertIn('line_limit',json.dumps(state))
                            self.assertFalse(any(e.get('text','').startswith('x'*4096) for e in state['run']['events']))
                        self.assertTrue(all(len(e['text'])<=4096 for e in state['run']['events'] if e['kind']=='log'))
        self.mode.write_text('second-line-4097-stdout-newline')
        preview=self.preview(p,['owner/one','owner/two']);p.confirm('session',self.payload(preview));state=self.wait(p)
        self.assertEqual(state['run']['outcome'],'partial',state)
        self.assertEqual([r['repo'] for r in state['run']['results']],['owner/one'])
        self.assertIn('line_limit',json.dumps(state))

    def test_unsafe_lock_open_refuses_without_consuming_or_dispatching(self):
        p=self.provider();preview=self.preview(p)
        target=self.base/'untouched-lock-target';target.write_text('untouched')
        def refused():
            with self.assertRaisesRegex(SyncError,'^sync_busy$'):p.confirm('session',self.payload(preview))
            self.assertEqual(p.snapshot('session')['phase'],'preview')
            self.assertEqual(p._preview['public']['preview_id'],preview['preview_id'])
            self.assertIsNone(p._lock_fd);self.assertFalse(self.called())
            self.assertFalse((self.base/'cockpit-sync.jsonl').exists())
        p.lock_path.symlink_to(target);refused();p.lock_path.unlink()
        self.assertEqual(target.read_text(),'untouched')
        p.lock_path.mkdir();refused();p.lock_path.rmdir()
        with mock.patch('mergepath.cockpit.sync.os.open',side_effect=PermissionError(13,'synthetic private detail')):
            refused()
        p.confirm('session',self.payload(preview));self.assertEqual(self.wait(p)['run']['outcome'],'success')

    def test_export_parser_is_data_only(self):
        for value in (b"export OP_PREFLIGHT_AUTHOR_PAT=$(evil)", b"export OP_PREFLIGHT_AUTHOR_PAT=", b"export GH_TOKEN=other",
                      b"export OP_PREFLIGHT_AUTHOR_PAT=a\nexport OP_PREFLIGHT_AUTHOR_PAT=b"):
            with self.assertRaises(SyncError):cached_author(value)
        self.assertEqual(cached_author(b"export OP_PREFLIGHT_AUTHOR_PAT=one\nexport OP_PREFLIGHT_REVIEWER_PAT=two"),"one")

    def test_verified_identity_applies_to_real_git_commit_in_actual_worker(self):
        p=self.provider();self.mode.write_text("identity");preview=self.preview(p)
        with mock.patch.dict(os.environ,{"GIT_AUTHOR_NAME":"ambient","GIT_AUTHOR_EMAIL":"ambient@example.invalid", "GIT_COMMITTER_NAME":"ambient","GIT_COMMITTER_EMAIL":"ambient@example.invalid"}):
            p.confirm("session",self.payload(preview));state=self.wait(p)
        self.assertEqual(state["run"]["outcome"],"success",state)
        self.assertEqual((self.base/'identity.txt').read_text(), 'Verified Fixture Author|fixture@example.invalid|Verified Fixture Author|fixture@example.invalid')

    def test_global_resolver_allowlist_and_unsupported_signing_keep_observations(self):
        fake=self.base/'identity-git'
        fake.write_text(f'''#!{sys.executable}
import os,sys
assert sys.argv[1:3]==['config','--global']
assert 'GH_TOKEN' not in os.environ and 'GIT_CONFIG_GLOBAL' not in os.environ
print({{'user.name':'Verified Fixture Author','user.email':'fixture@example.invalid','commit.gpgsign':'false'}}[sys.argv[-1]])
''');fake.chmod(0o700)
        with mock.patch.dict(os.environ,{'GH_TOKEN':'ambient','GIT_CONFIG_GLOBAL':'/bad'}):
            self.assertEqual(resolve_git_identity(str(fake)),IDENTITY)
        p=self.provider(git_identity={**IDENTITY,'signing':True})
        self.assertEqual(p.snapshot('session')['phase'],'idle')
        with self.assertRaisesRegex(SyncError,'unsupported_git_signing'):p.preview('session',{'repos':['owner/one']})
        self.assertFalse(self.called())

    def test_stale_incomplete_audit_and_unsafe_journal_refuse(self):
        p=self.provider();p.fetch=lambda deadline: Sample({'schema':'cockpit-fleet/v1','hub_repo':HUB,'repositories':[{'repo':r['repo'],'attempt':r,'stale':True} for r in json.loads(self.records.read_text())]})
        p.preview('session',{'repos':['owner/one']});self.assertEqual(self.wait(p)['error'],'audit_stale')
        p.fetch=self.fetch;preview=self.preview(p)
        journal=self.base/'cockpit-sync.jsonl';journal.symlink_to(self.base/'unrelated')
        with self.assertRaisesRegex(SyncError,'audit_log_unavailable'):p.confirm('session',self.payload(preview))
        self.assertFalse(self.called());self.assertFalse((self.base/'unrelated').exists())

    def test_silent_worker_startup_is_bounded_and_lock_released(self):
        import mergepath.cockpit.sync as sync_module
        p=self.provider();preview=self.preview(p)
        sleeper=self.base/'silent-python'
        sleeper.write_text('#!/bin/sh\nsleep 60\n');sleeper.chmod(0o700)
        p.tools['python']=str(sleeper)
        start=time.monotonic()
        with mock.patch.object(sync_module,'RUN_SECONDS',.25):
            p.confirm('session',self.payload(preview));state=self.wait(p)
        self.assertLess(time.monotonic()-start,2)
        self.assertEqual(state['error'],'deadline_exceeded')
        self.assertFalse(self.called())
        p.tools['python']=sys.executable
        preview=self.preview(p);p.confirm('session',self.payload(preview));self.assertEqual(self.wait(p)['phase'],'done')


if __name__ == "__main__":
    from unittest import mock
    unittest.main()
