#!/usr/bin/env python3
"""Offline #906 production-helper, reader and narrow recovery regressions."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

# Import the production selector without leaving binary cache files in the
# scripts tree scanned by repository source checks.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/workflow/coderabbit-evidence-recovery.py"
spec = importlib.util.spec_from_file_location("recovery", MODULE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)
HEAD = "a" * 40
REVISION = "b" * 40
CONTEXT = recovery.CONTEXT


def run_entry(number, result="SUCCESS", status="COMPLETED", native=False, app="15368", **extra):
    return dict(name=CONTEXT, databaseId=number, conclusion=result, status=status,
                kind="CheckRun", lineage="native" if native else "api", appId=app,
                startedAt=f"2026-10-14T12:00:0{number}Z", completedAt="2026-10-14T12:00:09Z", **extra)


class Reader(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "scripts/codex-review-check.sh").read_text()
        start = source.index("  # Pick the entry", source.index("BAD_CHECKS=$("))
        end = source.index("')", start)
        cls.program = source[start:end]

    def read(self, rows):
        command = ["jq", "--argjson", "requirements", json.dumps([{"context": CONTEXT, "app_id": "15368"}]),
                   "--arg", "requirements_state", "known", "--arg", "approval_readiness_only", "0",
                   "--arg", "current_run_id", "", "--argjson", "lineage_contexts", json.dumps([CONTEXT]), self.program]
        result = subprocess.run(command, input=json.dumps({"statusCheckRollup": rows}),
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_old_success_completing_last_cannot_clear_new_failure(self):
        older = run_entry(1, completedAtIgnored="")
        newer = run_entry(2, "FAILURE")
        newer["completedAt"] = "2026-10-14T12:00:03Z"
        self.assertTrue(self.read([older, newer]))

    def test_new_pending_wins_between_old_final_read_and_patch(self):
        self.assertTrue(self.read([run_entry(1), run_entry(2, "", "IN_PROGRESS")]))

    def test_new_success_retires_old_incomplete_opening(self):
        self.assertFalse(self.read([run_entry(1, "", "IN_PROGRESS"), run_entry(2)]))

    def test_native_pending_contract_is_unchanged(self):
        self.assertTrue(self.read([run_entry(1, "", "IN_PROGRESS", native=True), run_entry(2, native=True)]))

    def test_missing_opening_order_fails_closed(self):
        row = run_entry(1)
        del row["databaseId"]
        self.assertTrue(self.read([row]))

    def test_live_64_bit_server_id_is_preserved_and_fractional_ids_fail_closed(self):
        self.assertFalse(self.read([run_entry(91305386162)]))
        self.assertTrue(self.read([run_entry(1.5)]))

    def test_whole_second_tie_uses_server_id(self):
        rows = [run_entry(1), run_entry(2, "FAILURE")]
        rows[1]["startedAt"] = rows[0]["startedAt"]
        self.assertTrue(self.read(rows))


class Recovery(unittest.TestCase):
    def setUp(self):
        self.request = dict(repo="owner/repo", pr=7, head=HEAD, revision=REVISION,
                            kind="unrecognized", evidence="unchanged unknown review serialization",
                            max_wait_seconds=1245)
        self.opening = dict(id=100, name=CONTEXT, head_sha=HEAD, app={"id": 15368}, status="in_progress")
        self.runs = [self.opening]

    def observe(self, now=1000, comments=None, transitions=None):
        return recovery.select(self.request, self.runs, comments or [], transitions or [], now)

    def persist(self, report):
        self.runs[-1].update(status="completed", output={"summary":
            '<!-- mergepath-generation:v1 {} -->\n' + recovery.PREFIX + json.dumps(report) + " -->\nquoted data"})
        self.runs.append(dict(self.opening, id=self.runs[-1]["id"] + 1, status="in_progress"))
        self.runs[-1].pop("output", None)

    def release(self, report, **changes):
        comment = dict(id=123, user={"login": "nathanjohnpayne"}, created_at="1970-01-01T00:16:41Z",
                       updated_at="1970-01-01T00:16:41Z", body=report["recovery_token"] +
                       "\nReason: provider serialization is unreadable; independently checked this head.\n"
                       "Decision: https://github.com/owner/repo/issues/7#issuecomment-123")
        comment.update(changes)
        return comment

    def confirmed(self):
        first = self.observe()
        self.assertEqual(first["state"], "pending")
        self.persist(first)
        second = self.observe(1001)
        self.assertEqual(second["state"], "escalate")
        return second

    def test_unrecognized_requires_a_second_identical_observation(self):
        self.confirmed()

    def test_elapsed_time_does_not_create_a_clean_verdict(self):
        self.assertEqual(self.observe(999999)["state"], "pending")

    def test_explicit_release_is_labeled_recovery(self):
        report = self.confirmed()
        result = self.observe(1002, [self.release(report)])
        self.assertEqual(result["state"], "recovery")
        self.assertIn("issuecomment-123", result["decision"])

    def test_wrong_author_head_pr_reason_or_decision_is_not_a_release(self):
        report = self.confirmed()
        good = self.release(report)
        mutations = [dict(good, user={"login": "someone-else"}),
                     dict(good, body=good["body"].replace(HEAD, "c" * 40)),
                     dict(good, body=good["body"].replace("owner/repo 7 ", "owner/repo 8 ")),
                     dict(good, body=good["body"].replace("Reason:", "Quoted reason:")),
                     dict(good, body=good["body"].replace("issuecomment-123", "issuecomment-124"))]
        for comment in mutations:
            with self.subTest(comment=comment):
                self.assertEqual(self.observe(1002, [comment])["state"], "escalate")

    def test_oversized_reason_cannot_truncate_the_canonical_recovery_header(self):
        report = self.confirmed()
        comment = self.release(report)
        comment["body"] = report["recovery_token"] + "\nReason: " + "x" * 4001 + "\nDecision: https://github.com/owner/repo/issues/7#issuecomment-123"
        self.assertEqual(self.observe(1002, [comment])["state"], "escalate")

    def test_replayed_release_after_readable_verdict_is_rejected(self):
        report = self.confirmed()
        release = self.release(report)
        readable = dict(repo="owner/repo", pr=7, head=HEAD, revision=REVISION, state="readable")
        self.runs[-1].update(status="completed", output={"summary":
            '<!-- mergepath-generation:v1 {} -->\n' + recovery.PREFIX + json.dumps(readable) + " -->"})
        self.runs.append(dict(self.opening, id=102, status="in_progress", output={}))
        self.assertEqual(self.observe(1002, [release])["state"], "pending")

    def test_changed_evidence_and_a_b_a_transition_reject_old_release(self):
        report = self.confirmed()
        release = self.release(report)
        self.request["evidence"] = "later changed serialization"
        self.assertNotEqual(self.observe(1002, [release])["state"], "recovery")
        self.request["evidence"] = "unchanged unknown review serialization"
        self.assertNotEqual(self.observe(1002, [release], [{"id": 55, "event": "head_ref_force_pushed"}])["state"], "recovery")

    def test_unreadable_retries_for_existing_wait_and_retry_after_windows(self):
        self.request.update(kind="unreadable", retry_after=2000)
        first = self.observe()
        self.persist(first)
        self.request["retry_after"] = 1999
        second = self.observe(1001)
        self.assertEqual(second["retry_until"], 3000)
        self.persist(second)
        self.request["retry_after"] = 0
        self.assertEqual(self.observe(2246)["state"], "pending")
        self.assertEqual(self.observe(3000)["state"], "escalate")
        self.assertNotEqual(self.observe(3000)["state"], "recovery")

    def test_untyped_infrastructure_failure_preserves_episode_and_retry_deadline(self):
        self.request.update(kind="unreadable")
        first = self.observe(1000)
        self.persist(first)
        self.runs[-1].update(status="completed", conclusion="failure", output={"summary": "fingerprint changed; retry"})
        self.runs.append(dict(self.opening, id=102, status="in_progress", output={}))
        result = self.observe(3000)
        self.assertEqual(result["state"], "escalate")
        self.assertEqual(result["first_observed"], 1000)
        self.assertEqual(result["episode"], first["episode"])
        self.assertEqual(result["retry_until"], 2245)
        self.assertNotEqual(result["state"], "recovery")

    def test_untyped_infrastructure_failure_does_not_erase_unknown_confirmation(self):
        first = self.observe()
        self.persist(first)
        self.runs[-1].update(status="completed", conclusion="failure", output={})
        self.runs.append(dict(self.opening, id=102, status="in_progress", output={}))
        result = self.observe(1001)
        self.assertEqual(result["state"], "escalate")
        self.assertEqual(result["episode"], first["episode"])
        self.assertEqual(result["observations"], 2)

    def test_duplicate_or_old_comment_is_not_fresh_authority(self):
        report = self.confirmed()
        comment = self.release(report)
        self.assertEqual(self.observe(1002, [comment, dict(comment, id=124, body=comment["body"].replace("issuecomment-123", "issuecomment-124"))])["state"], "escalate")
        comment["created_at"] = "1970-01-01T00:00:00Z"
        self.assertEqual(self.observe(1002, [comment])["state"], "escalate")

    def test_quoted_header_is_not_a_publisher_observation(self):
        self.opening.update(status="completed", output={"summary": "quoted\n" + recovery.PREFIX + "{} -->"})
        self.assertEqual(self.observe()["observations"], 1)


class Escalation(unittest.TestCase):
    def exercise_two_nominations(self, first_override=None):
        posts = []
        heads = {7: HEAD, 8: "c" * 40}

        def api(path):
            if path.endswith("/commits/HEAD"):
                return {"sha": REVISION}
            number = int(path.rsplit("/", 1)[1])
            return {"number": number, "head": {"sha": heads[number]}}

        def pages(path, field=None):
            if "/check-runs?" not in path:
                return []
            number = 7 if HEAD in path else 8
            report = dict(repo="owner/repo", pr=number, head=heads[number],
                          revision="d" * 40 if number == 7 else REVISION,
                          fingerprint="f" * 64, episode=100, state="escalate",
                          kind="unreadable", recovery_token="exact recovery token")
            if number == 7 and first_override is not None:
                report.update(first_override)
            return [dict(id=101, name=CONTEXT, app={"id": 15368}, output={"summary":
                '<!-- mergepath-generation:v1 {} -->\n' + recovery.PREFIX + json.dumps(report) + " -->"})]

        def write(path, body):
            posts.append((path, body))
            return body

        with mock.patch.object(recovery, "api", side_effect=api), \
                mock.patch.object(recovery, "pages", side_effect=pages), \
                mock.patch.object(recovery, "write", side_effect=write):
            recovery.escalate("owner/repo", "7 8")
        return posts

    def test_stale_first_nomination_does_not_prevent_later_current_escalation(self):
        posts = self.exercise_two_nominations()
        self.assertEqual([path for path, _ in posts], ["repos/owner/repo/issues/8/comments"])
        self.assertIn("c" * 40, posts[0][1]["body"])

    def test_malformed_first_tuple_retains_fail_closed_error(self):
        for override in ({"repo": None}, {"repo": "owner"}, {"pr": "7"}, {"pr": True},
                         {"pr": 0}, {"head": "short"}, {"revision": None}):
            with self.subTest(override=override), self.assertRaisesRegex(ValueError, "malformed escalation tuple"):
                self.exercise_two_nominations(override)

    def exercise(self, existing=False, already_posted=False):
        report = dict(repo="owner/repo", pr=7, head=HEAD, revision=REVISION, fingerprint="f" * 64,
                      episode=100, state="escalate", kind="unrecognized", recovery_token="exact recovery token")
        run = dict(id=101, name=CONTEXT, app={"id": 15368}, output={"summary":
            '<!-- mergepath-generation:v1 {} -->\n' + recovery.PREFIX + json.dumps(report) + " -->"})
        posts = []

        def api(path):
            if path.endswith("/commits/HEAD"):
                return {"sha": REVISION}
            return {"number": 7, "head": {"sha": HEAD}}

        def pages(path, field=None):
            if "/check-runs?" in path:
                return [run]
            if path.endswith("/issues?state=open&per_page=100"):
                return [{"number": 55, "html_url": "https://github.com/owner/repo/issues/55",
                         "body": "<!-- mergepath-coderabbit-parser-drift:v1 -->\nExisting work"}] if existing else []
            if already_posted and "/issues/7/comments?" in path:
                return [{"user": {"login": "github-actions[bot]"}, "body":
                         f"<!-- mergepath-coderabbit-escalation:v1 100 {'f' * 64} -->\nAlready reported"}]
            return []

        def write(path, body):
            posts.append((path, body))
            return dict(body, number=55, html_url="https://github.com/owner/repo/issues/55")

        with mock.patch.object(recovery, "api", side_effect=api), \
                mock.patch.object(recovery, "pages", side_effect=pages), \
                mock.patch.object(recovery, "write", side_effect=write):
            recovery.escalate("owner/repo", "7")
        return posts

    def test_persistent_unknown_opens_parser_work_and_reports_only_the_affected_gate(self):
        posts = self.exercise()
        self.assertEqual([path for path, _ in posts], ["repos/owner/repo/issues", "repos/owner/repo/issues/7/comments"])
        self.assertIn("all other gates remain required", posts[-1][1]["body"])
        self.assertIn("not independent human identity proof", posts[-1][1]["body"])
        self.assertIn("API recovery alone does not clear a native failure", posts[-1][1]["body"])
        self.assertIn("exact unchanged full head", posts[-1][1]["body"])

    def test_existing_parser_work_gets_the_new_evidence_without_duplication(self):
        posts = self.exercise(existing=True)
        self.assertEqual([path for path, _ in posts], ["repos/owner/repo/issues/55/comments", "repos/owner/repo/issues/7/comments"])
        self.assertFalse(self.exercise(existing=True, already_posted=True))


class OwnedGeneration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.env = dict(os.environ, GH_TOKEN="offline-fixture-token", HOME=str(self.path),
                        PATH=str(self.path) + os.pathsep + os.environ["PATH"], FIXTURE=str(self.path / "state.json"))
        (self.path / "git").write_text(f"#!/bin/sh\necho {REVISION}\n")
        (self.path / "git").chmod(0o755)
        (self.path / "state.json").write_text(json.dumps(dict(runs=[], writes=[], head=HEAD, revision=REVISION, heads=[7])))
        (self.path / "scripts/workflow").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/workflow/required-check-generation.sh", self.path / "scripts/workflow")
        gate = '''#!/usr/bin/env bash
python3 - "$FIXTURE" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); s=json.loads(p.read_text()); r=s['runs'][-1]
assert r['status']=='in_progress',r
s.setdefault('evaluated',[]).append(r['id']); p.write_text(json.dumps(s))
PY
echo 'Merge clearance: PASS'
'''
        for name in ("merge-clearance-gate.sh", "coderabbit-severity-gate.sh", "codex-p1-gate.sh"):
            target = self.path / "scripts" / name
            target.write_text(gate)
            target.chmod(0o755)
        self.env.update(TMPDIR=str(self.path), REPO="owner/repo", CHECK_NAME=CONTEXT,
                        PR="7", PR_NUMBER="7", MCG_CONTEXT="Merge clearance gate",
                        CODEX_P1_CONTEXT="Codex P1 unresolved threads", CODERABBIT_CONTEXT=CONTEXT)
        (self.path / "gh").write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
p=Path(os.environ['FIXTURE']); s=json.loads(p.read_text())
if sys.argv[1:3]==['pr','list']:
 rows=[{'number':n,'headRefOid':s['head']} for n in s['heads']]
 query=sys.argv[sys.argv.index('--jq')+1]
 print(subprocess.run(['jq','-r',query],input=json.dumps(rows),text=True,capture_output=True,check=True).stdout)
 sys.exit(0)
args=sys.argv[2:]; fields={}; method='GET'; query=None; endpoint=None
while args:
 a=args.pop(0)
 if a=='-X': method=args.pop(0)
 elif a in ('-f','-F'): k,v=args.pop(0).split('=',1); fields[k]=v
 elif a=='--jq': query=args.pop(0)
 elif not a.startswith('-'): endpoint=a
if method=='POST':
 r={'id':len(s['runs'])+1, 'head_sha':fields['head_sha'], 'name':fields['name'], 'status':fields['status'], 'output':{'summary':fields['output[summary]']}}
 s['runs'].append(r); s['writes'].append([method,r['id']])
elif method=='PATCH':
 if s.get('inject_pending'):
  s['inject_pending']=False
  s['runs'].append({'id':len(s['runs'])+1,'head_sha':s['head'],'name':fields.get('name','CodeRabbit unresolved blocking findings'),'status':'in_progress','output':{}})
 r=next(r for r in s['runs'] if r['id']==int(endpoint.rsplit('/',1)[1])); r.update(status=fields['status'],conclusion=fields['conclusion'],output={'summary':fields['output[summary]'],'title':fields['output[title]']}); s['writes'].append([method,r['id']])
elif '/check-runs/' in endpoint: r=next(r for r in s['runs'] if r['id']==int(endpoint.rsplit('/',1)[1]))
elif endpoint.endswith('/commits/HEAD'): r={'sha':s['revision']}
elif endpoint.endswith('/pulls/7'):
 if s.get('move_after_open') and s['runs']:
  s['head']=s.pop('move_after_open')
 r={'head':{'sha':s['head']}}
elif endpoint.endswith('/pulls'): r=[{'number':n,'head':{'sha':s['head']}} for n in s['heads']]
elif endpoint.endswith('/pulls/7/comments') and s.get('provider_blocked'):
 r=[{'id':2001,'user':{'login':'coderabbitai[bot]'},'commit_id':s['head'],'body':'**⚠️ Potential issue** | **Major**\\nThis pointer can be null.','path':'file.sh','line':1}]
elif endpoint.endswith(('/comments','/reviews')): r=[]
elif endpoint=='graphql':
 nodes=[{'id':'thread','isResolved':False,'comments':{'nodes':[{'databaseId':2001}],'pageInfo':{'hasNextPage':False,'endCursor':None}}}] if s.get('provider_blocked') else []
 r={'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':nodes,'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}}
else: raise AssertionError(endpoint)
p.write_text(json.dumps(s))
out=json.dumps(r)
if query: out=subprocess.run(['jq','-r',query],input=out,text=True,capture_output=True,check=True).stdout
print(out)
''')
        (self.path / "gh").chmod(0o755)

    def shell(self, program):
        prefix = f'. "{ROOT}/scripts/workflow/required-check-generation.sh"\n'
        process = subprocess.Popen(["bash", "-euc", prefix + program], env=self.env, cwd=self.path,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def state(self):
        return json.loads((self.path / "state.json").read_text())

    def test_interleaved_producers_patch_only_their_pre_evaluation_id(self):
        command = f'''old=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')
new=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')
rcg_close owner/repo 7 {HEAD} '{CONTEXT}' "$new" failure 'new finding' blocked
rcg_close owner/repo 7 {HEAD} '{CONTEXT}' "$old" success 'old success' clean'''
        result = self.shell(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.state()
        self.assertEqual(state["writes"], [["POST", 1], ["POST", 2], ["PATCH", 2], ["PATCH", 1]])
        self.assertEqual(max(state["runs"], key=lambda r: r["id"])["conclusion"], "failure")

    def test_wrong_owned_tuple_is_never_patched(self):
        result = self.shell(f"id=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')\n"
                            f"rcg_close owner/repo 8 {HEAD} '{CONTEXT}' \"$id\" success title clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state()["writes"], [["POST", 1]])

    def test_pending_arrives_inside_final_read_to_patch_gap(self):
        state = self.state()
        state["inject_pending"] = True
        (self.path / "state.json").write_text(json.dumps(state))
        result = self.shell(f"id=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')\n"
                            f"rcg_close owner/repo 7 {HEAD} '{CONTEXT}' \"$id\" success title clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = self.state()["runs"]
        self.assertEqual(runs[0]["conclusion"], "success")
        self.assertEqual(runs[1]["status"], "in_progress")
        Reader.setUpClass()
        self.assertTrue(Reader().read([run_entry(r["id"], r.get("conclusion", "").upper(),
                                                  r["status"].upper()) for r in runs]))

    def workflow_step(self, filename, job, needle):
        command = ["ruby", "-ryaml", "-rjson", "-e",
                   'd=YAML.load_file(ARGV[0]); s=d.fetch("jobs").fetch(ARGV[1]).fetch("steps").select { |s| s["run"].to_s.include?(ARGV[2]) }; abort("ambiguous step") unless s.length==1; puts JSON.dump(s[0]["run"])',
                   str(ROOT / ".github/workflows" / filename), job, needle]
        return json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)

    def test_escalation_permission_map_is_isolated_to_trusted_comment_writer(self):
        source = ROOT / ".github/workflows/required-check-publisher.yml"
        command = ["ruby", "-ryaml", "-rjson", "-e", 'puts JSON.dump(YAML.load_file(ARGV[0])["jobs"]["escalate-coderabbit-evidence"])', str(source)]
        job = json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)
        self.assertEqual(job["permissions"], {"contents": "read", "pull-requests": "write", "checks": "read", "issues": "write"})
        self.assertEqual(job["needs"], "publish")
        self.assertEqual(job["steps"][0]["with"]["ref"], "${{ github.event.repository.default_branch }}")
        posts = Escalation().exercise()
        self.assertTrue(posts)
        self.assertTrue(all("/check-runs" not in path for path, _ in posts))

    def test_native_recovery_rerun_is_required_and_does_not_write_checks(self):
        Reader.setUpClass()
        reader = Reader()
        self.assertTrue(reader.read([run_entry(1, "FAILURE", native=True), run_entry(2)]))
        self.assertFalse(reader.read([run_entry(1, "FAILURE", native=True), run_entry(2), run_entry(3, native=True)]))
        native_gate = self.path / "scripts/coderabbit-severity-gate.sh"
        native_gate.write_text("#!/bin/sh\necho 'CodeRabbit gate RECOVERY (not a clean provider review): exact decision'\nexit 0\n")
        result = self.shell(self.workflow_step("coderabbit-severity-gate.yml", "coderabbit-severity-gate", 'scripts/coderabbit-severity-gate.sh "$PR_NUMBER"'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RECOVERY (not a clean provider review)", result.stdout)
        self.assertEqual(self.state()["writes"], [])

    def test_actual_evaluator_records_only_readable_verdicts(self):
        (self.path / ".github").mkdir()
        (self.path / ".github/review-policy.yml").write_text("coderabbit:\n  severity_gate:\n    enabled: true\n")
        report = self.path / "report.json"
        self.env["CR_EVIDENCE_REPORT"] = str(report)
        for blocked in (False, True):
            with self.subTest(blocked=blocked):
                state = self.state()
                state["provider_blocked"] = blocked
                (self.path / "state.json").write_text(json.dumps(state))
                result = self.shell(f'"{ROOT}/scripts/coderabbit-severity-gate.sh" 7 owner/repo')
                self.assertEqual(result.returncode, int(blocked), result.stdout + result.stderr)
                self.assertEqual(json.loads(report.read_text()), dict(repo="owner/repo", pr=7, head=HEAD, revision=REVISION, state="readable"))

    def test_final_binding_failure_cannot_publish_a_readable_marker(self):
        report = self.path / "report.json"
        report.write_text(json.dumps(dict(repo="owner/repo", pr=7, head=HEAD, revision=REVISION, state="readable")))
        self.env["CR_EVIDENCE_REPORT"] = str(report)
        state = self.state()
        state["revision"] = "c" * 40
        (self.path / "state.json").write_text(json.dumps(state))
        result = self.shell(f"id=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')\n"
                            f"rcg_close owner/repo 7 {HEAD} '{CONTEXT}' \"$id\" success title clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(recovery.PREFIX, self.state()["runs"][0]["output"]["summary"])
        self.assertEqual(self.state()["writes"], [["POST", 1], ["PATCH", 1]])
        self.assertEqual(self.state()["runs"][0]["conclusion"], "failure")

    def test_wrong_report_tuple_without_final_drift_cannot_publish_success(self):
        report = self.path / "report.json"
        report.write_text(json.dumps(dict(repo="owner/repo", pr=7, head="c" * 40,
                                         revision=REVISION, state="readable")))
        self.env["CR_EVIDENCE_REPORT"] = str(report)
        result = self.shell(f"id=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')\n"
                            f"rcg_close owner/repo 7 {HEAD} '{CONTEXT}' \"$id\" success title clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state()["writes"], [["POST", 1]])
        self.assertEqual(self.state()["runs"][0]["status"], "in_progress")

    def test_real_legacy_sweep_and_dispatch_open_before_evaluation(self):
        for filename, job, needle in [
            ("merge-clearance-gate.yml", "scheduled-sweep", "output=$(scripts/merge-clearance-gate.sh"),
            ("merge-clearance-gate.yml", "dispatch-recheck", "output=$(scripts/merge-clearance-gate.sh"),
            ("coderabbit-severity-gate.yml", "scheduled-sweep", "cr_surface_fp()")]:
            with self.subTest(job=job, workflow=filename):
                state = dict(runs=[], writes=[], head=HEAD, revision=REVISION, heads=[7])
                (self.path / "state.json").write_text(json.dumps(state))
                self.env["PRS"] = "7" if filename.startswith("coderabbit") else "7\t" + HEAD
                self.env["CHECK_NAME"] = CONTEXT if filename.startswith("coderabbit") else "Merge clearance gate"
                result = self.shell(self.workflow_step(filename, job, needle))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.state()["evaluated"], [1])
                self.assertEqual(self.state()["writes"], [["POST", 1], ["PATCH", 1]])

    def test_legacy_sweep_closes_original_generation_when_head_moves_after_open(self):
        (self.path / ".github").mkdir()
        (self.path / ".github/review-policy.yml").write_text("coderabbit:\n  severity_gate:\n    enabled: true\n")
        gate = self.path / "scripts/coderabbit-severity-gate.sh"
        gate.write_text(gate.read_text().replace("echo 'Merge clearance: PASS'",
                        f'exec "{ROOT}/scripts/coderabbit-severity-gate.sh" "$@"'))
        state = self.state()
        state["move_after_open"] = "c" * 40
        (self.path / "state.json").write_text(json.dumps(state))
        self.env["PRS"] = "7"
        result = self.shell(self.workflow_step("coderabbit-severity-gate.yml", "scheduled-sweep", "cr_surface_fp()"))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        state = self.state()
        self.assertEqual(state["evaluated"], [1])
        self.assertEqual(state["writes"], [["POST", 1], ["PATCH", 1]])
        self.assertEqual(state["runs"][0]["head_sha"], HEAD)
        self.assertEqual(state["runs"][0]["conclusion"], "failure")
        self.assertIn("generation input changed", state["runs"][0]["output"]["title"])

    def test_consolidated_gate_opens_every_selected_context_before_evaluation(self):
        program = self.workflow_step("required-check-publisher.yml", "publish", "gate() {")
        start = program.index("gate() {")
        end = program.index("\n}", start) + 2
        gate = program[start:end]
        setup = "OWN_GENERATIONS=''; RATE_LIMITED=0; had_infra_error=0; EVIDENCE_ESCALATIONS=''; MCG_GREEN_PRS=''\n"
        calls = "\n".join(f"gate scripts/{script} '{context}' '' 7 {HEAD} {flag}" for script, context, flag in [
            ("merge-clearance-gate.sh", "Merge clearance gate", "false"),
            ("codex-p1-gate.sh", "Codex P1 unresolved threads", "false"),
            ("coderabbit-severity-gate.sh", CONTEXT, "true")])
        result = self.shell(setup + gate + "\n" + calls)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state()["evaluated"], [1, 2, 3])
        self.assertEqual(self.state()["writes"], [["POST", 1], ["PATCH", 1], ["POST", 2], ["PATCH", 2], ["POST", 3], ["PATCH", 3]])

    def test_trusted_revision_drift_duplicate_head_and_head_drift_publish_no_success(self):
        for key, value in [("revision", "c" * 40), ("heads", [7, 8]), ("head", "c" * 40)]:
            with self.subTest(key=key):
                path = self.path / "state.json"
                state = dict(runs=[], writes=[], head=HEAD, revision=REVISION, heads=[7])
                state[key] = value
                path.write_text(json.dumps(state))
                self.shell(f"id=$(rcg_open owner/repo 7 {HEAD} '{CONTEXT}')\n"
                           f"rcg_close owner/repo 7 {HEAD} '{CONTEXT}' \"$id\" success title clean")
                self.assertEqual(self.state()["runs"][0]["conclusion"], "failure")


if __name__ == "__main__":
    unittest.main()
