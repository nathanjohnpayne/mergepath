#!/usr/bin/env python3
"""Offline #906 production-helper, reader and narrow recovery regressions."""
import importlib.util
import io
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

    def test_configured_author_can_release_but_unrelated_and_legacy_authors_cannot(self):
        self.request["author_identity"] = "configured-owner"
        report = self.confirmed()
        custom = self.release(report, user={"login": "configured-owner"})
        self.assertEqual(self.observe(1002, [custom])["state"], "recovery")
        for login in ("unrelated-user", "nathanjohnpayne"):
            with self.subTest(login=login):
                self.assertEqual(self.observe(1002, [dict(custom, user={"login": login})])["state"], "escalate")

    def test_unset_author_retains_the_legacy_fallback(self):
        report = self.confirmed()
        self.assertEqual(self.observe(1002, [self.release(report)])["state"], "recovery")

    def test_malformed_explicit_author_is_unreadable(self):
        for author in (None, "", True, 7, [], {}):
            with self.subTest(author=author), self.assertRaisesRegex(ValueError, "recovery author"):
                self.request["author_identity"] = author
                self.observe()

    def test_author_change_starts_a_new_bound_episode(self):
        self.confirmed()
        self.request["author_identity"] = "configured-owner"
        self.assertEqual(self.observe(1002)["state"], "pending")

    def test_policy_base_change_cannot_release_recovery(self):
        self.request["base_sha"] = "c" * 40
        report = self.confirmed()
        comment = self.release(report)
        def pages(path, field=None):
            if "/check-runs?" in path:
                return self.runs
            return [comment] if "/comments?" in path else []
        for actual in ("c" * 40, "d" * 40):
            with self.subTest(actual=actual), \
                    mock.patch.object(recovery, "pages", side_effect=pages), \
                    mock.patch.object(recovery, "api", side_effect=lambda path:
                        {"sha": REVISION} if path.endswith("/commits/HEAD") else
                        {"head":{"sha":HEAD},"base":{"sha":actual}}), \
                    mock.patch.object(recovery.time, "time", return_value=1002), \
                    mock.patch.object(sys, "argv", [str(MODULE)]), \
                    mock.patch.object(sys, "stdin", io.StringIO(json.dumps(self.request))), \
                    mock.patch.object(sys, "stdout", new_callable=io.StringIO) as output:
                if actual == "c" * 40:
                    self.assertEqual(recovery.main(), 0)
                    self.assertEqual(json.loads(output.getvalue())["state"], "recovery")
                else:
                    with self.assertRaisesRegex(ValueError, "binding changed"):
                        recovery.main()
                    self.assertEqual(output.getvalue(), "")

    def test_malformed_explicit_policy_base_is_unreadable(self):
        for base in (None, "", True, "short", [], {}):
            with self.subTest(base=base), self.assertRaisesRegex(ValueError, "policy base"):
                self.request["base_sha"] = base
                self.observe()

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


class RecoverySubprocessDeadline(unittest.TestCase):
    def test_real_read_and_uncertain_write_time_out_without_clearance_or_retry(self):
        # Exercise the CLI and actual subprocess deadline; no credential or API
        # access is possible because gh is replaced by this bounded fixture.
        for mode in ("read", "write"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                calls = root / "calls.jsonl"
                fake = root / "gh"
                report = dict(repo="owner/repo", pr=7, head=HEAD, revision=REVISION,
                              episode=100, fingerprint="f" * 64, state="escalate",
                              kind="unrecognized", recovery_token="exact token")
                run = dict(id=101, name=CONTEXT, app={"id": 15368},
                           output={"summary": '<!-- mergepath-generation:v1 {} -->\n' +
                                   recovery.PREFIX + json.dumps(report) + " -->"})
                fake.write_text("#!" + sys.executable + "\n" +
                    "import json,sys,time\nfrom pathlib import Path\n" +
                    "args=sys.argv[1:]; path=args[-1]\n" +
                    "writing='--method' in args\n" +
                    "with Path(" + repr(str(calls)) + ").open('a') as out: " +
                    "out.write(json.dumps(args)+'\\n')\n" +
                    "if writing or " + repr(mode == "read") + ":\n" +
                    " print('{\"state\":\"recovery\"}',flush=True);time.sleep(120)\n" +
                    "elif path.endswith('/commits/HEAD'): print(json.dumps({'sha':" + repr(REVISION) + "}))\n" +
                    "elif '/pulls/' in path: print(json.dumps({'number':7,'head':{'sha':" + repr(HEAD) + "}}))\n" +
                    "elif '/check-runs?' in path: print(json.dumps([{'check_runs':[" + repr(run) + "]}]))\n" +
                    "else: print('[[]]')\n")
                fake.chmod(0o755)
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"])
                command = [sys.executable, str(MODULE)]
                if mode == "write":
                    command += ["--escalate", "owner/repo", "7"]
                process = subprocess.Popen(command, env=env, text=True,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                try:
                    stdout, stderr = process.communicate(json.dumps(dict(repo="owner/repo", pr=7, head=HEAD)), timeout=45)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    stdout, stderr = process.communicate()
                    self.fail("recovery helper exceeded its per-call deadline")
                self.assertEqual(process.returncode, 3, stderr)
                self.assertEqual(stdout, "")
                self.assertIn("CodeRabbit recovery evidence unreadable: TimeoutExpired", stderr)
                attempts = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertEqual(sum("--method" in call for call in attempts), mode == "write")
                if mode == "read":
                    self.assertEqual(len(attempts), 1)


class RecoveryAuthorCaller(unittest.TestCase):
    def call(self, policy, fail_resolver=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            workflow = scripts / "workflow"
            workflow.mkdir(parents=True)
            governing = root / "governing.yml"
            governing.write_text(policy)
            materialized = root / "materialized.yml"
            config = root / "checkout.yml"
            config.write_text("author_identity: wrong-checkout-owner\ncoderabbit: {max_wait_seconds: 1245}\n")
            resolver = workflow / "resolve_base_policy.sh"
            arguments = root / "resolver-args.json"
            resolver.write_text("#!" + sys.executable + "\nimport json,shutil,sys\n" +
                "from pathlib import Path\nPath(" + repr(str(arguments)) +
                ").write_text(json.dumps(sys.argv[1:]))\n" +
                "if " + repr(fail_resolver) + ": sys.exit(2)\n" +
                "shutil.copyfile(" + repr(str(governing)) + "," + repr(str(materialized)) + ")\n" +
                "print(" + repr(str(materialized)) + ")\n")
            resolver.chmod(0o755)
            captured = root / "request.json"
            (workflow / "coderabbit-evidence-recovery.py").write_text(
                "import sys\nfrom pathlib import Path\nPath(" + repr(str(captured)) +
                ").write_text(sys.stdin.read())\nsys.exit(3)\n")
            source = (ROOT / "scripts/coderabbit-severity-gate.sh").read_text()
            start = source.index("cr_recovery_author() (")
            end = source.index("\ncr_fingerprint_hold() {", start)
            # All runtime functions and YAML parsing are production code. Only
            # policy resolution and the API-consuming helper are substituted.
            script = 'source "$1"; CONFIG="$2"; SCRIPT_ROOT="$3"; PR_JSON="$4"; REPO=owner/repo; PR_NUMBER=7; HEAD_SHA=' + HEAD + "; CR_FINDINGS_KNOWN_CLEAN=1; " + source[start:end] + "\ncr_evidence_hold unrecognized fixture"
            result = subprocess.run(["bash", "-c", script, "fixture",
                str(ROOT / "scripts/lib/feedback-policy-helpers.sh"), str(config), str(scripts),
                json.dumps({"base":{"sha":"c" * 40,"ref":"release","repo":{"default_branch":"main"}}})],
                cwd=ROOT, capture_output=True, text=True, timeout=20)
            args = json.loads(arguments.read_text())
            self.assertEqual(args, ["--repo", "owner/repo", "--base-ref", "release", "--base-sha", "c" * 40, "--default-branch", "main", "--default-config", str(config), "--materialize-default"])
            self.assertFalse(materialized.exists(), "materialized policy must be cleaned up")
            return result, json.loads(captured.read_text()) if captured.exists() else None

    def test_caller_uses_governing_author_and_keeps_typed_default(self):
        for policy, author in (("author_identity: configured-owner\n", "configured-owner"),
                               ("{}\n", "nathanjohnpayne")):
            with self.subTest(policy=policy):
                result, request = self.call(policy)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertEqual(request["author_identity"], author)
                self.assertEqual(request["base_sha"], "c" * 40)
                self.assertEqual(request["repo"], "owner/repo")
                self.assertEqual(request["pr"], 7)
                self.assertEqual(request["head"], HEAD)

    def test_unreadable_or_malformed_governing_policy_never_calls_recovery(self):
        for policy, failed in (("{}", True), ("[invalid", False), ("[]", False),
                               ("author_identity: null", False), ("author_identity: false", False),
                               ('author_identity: ""', False)):
            with self.subTest(policy=policy, failed=failed):
                result, request = self.call(policy, failed)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIsNone(request)


class Escalation(unittest.TestCase):
    def exercise_two_nominations(self, first_override=None, first_failure=None, failure_at="api", missing_field=None, first_run_override=None):
        posts = []
        heads = {7: HEAD, 8: "c" * 40}

        def api(path):
            if path.endswith("/commits/HEAD"):
                return {"sha": REVISION}
            number = int(path.rsplit("/", 1)[1])
            if number == 7 and first_failure is not None and failure_at == "api":
                raise first_failure
            return {"number": number, "head": {"sha": heads[number]}}

        def pages(path, field=None):
            if "/check-runs?" not in path:
                return []
            number = 7 if HEAD in path else 8
            if number == 7 and first_failure is not None and failure_at == "pages":
                raise first_failure
            report = dict(repo="owner/repo", pr=number, head=heads[number],
                          revision="d" * 40 if number == 7 else REVISION,
                          fingerprint="f" * 64, episode=100, state="escalate",
                          kind="unreadable", recovery_token="exact recovery token")
            if number == 7 and first_override is not None:
                report.update(first_override)
            if number == 7 and missing_field is not None:
                report.pop(missing_field)
            run = dict(id=101, name=CONTEXT, app={"id": 15368}, output={"summary":
                '<!-- mergepath-generation:v1 {} -->\n' + recovery.PREFIX + json.dumps(report) + " -->"})
            if number == 7 and first_run_override is not None:
                run.update(first_run_override)
            return [run]

        def write(path, body):
            posts.append((path, body))
            if path.endswith("/7/comments") and first_failure is not None and failure_at == "write":
                raise first_failure
            return body

        with mock.patch.object(recovery, "api", side_effect=api), \
                mock.patch.object(recovery, "pages", side_effect=pages), \
                mock.patch.object(recovery, "write", side_effect=write), \
                mock.patch.object(sys, "argv", [str(MODULE), "--escalate", "owner/repo", "7 8"]), \
                mock.patch.object(sys, "stderr", new_callable=io.StringIO) as diagnostics:
            code = recovery.main()
        return posts, code, diagnostics.getvalue()

    def test_stale_first_nomination_does_not_prevent_later_current_escalation(self):
        posts, code, _ = self.exercise_two_nominations()
        self.assertEqual(code, 0)
        self.assertEqual([path for path, _ in posts], ["repos/owner/repo/issues/8/comments"])
        self.assertIn("c" * 40, posts[0][1]["body"])

    def assert_later_target_survives(self, **kwargs):
        posts, code, diagnostic = self.exercise_two_nominations(**kwargs)
        self.assertEqual(code, 3)
        self.assertEqual(posts[-1][0], "repos/owner/repo/issues/8/comments")
        self.assertIn("PR #7", diagnostic)
        # A failed write may already have happened; it must not be retried.
        self.assertLessEqual(sum(path.endswith("/7/comments") for path, _ in posts), 1)
        return diagnostic

    def test_malformed_first_tuple_fails_command_but_allows_later_escalation(self):
        for override in ({"repo": None}, {"repo": "owner"}, {"pr": "7"}, {"pr": True},
                         {"pr": 0}, {"head": "short"}, {"revision": None}):
            with self.subTest(override=override):
                diagnostic = self.assert_later_target_survives(first_override=override)
                self.assertIn("ValueError", diagnostic)

    def test_missing_first_tuple_fields_do_not_suppress_later_target(self):
        for field in ("pr", "head", "revision", "repo"):
            with self.subTest(field=field):
                self.assert_later_target_survives(missing_field=field)

    def test_malformed_nested_first_observation_does_not_suppress_later_target(self):
        for record in ({"output": None}, {"output": []}, {"app": None}, {"app": []}):
            with self.subTest(record=record):
                self.assert_later_target_survives(first_run_override=record)

    def test_first_target_transport_and_evidence_errors_are_isolated(self):
        errors = [KeyError("head"), TypeError("malformed header"), ValueError("damaged evidence"),
                  OSError("transport unavailable"), subprocess.CalledProcessError(1, ["gh", "api"]),
                  subprocess.TimeoutExpired(["gh", "api"], 30)]
        for stage in ("api", "pages", "write"):
            for error in errors:
                with self.subTest(stage=stage, error=type(error).__name__):
                    diagnostic = self.assert_later_target_survives(
                        first_override={"revision": REVISION}, first_failure=error, failure_at=stage)
                    self.assertIn(type(error).__name__, diagnostic)

    def exercise(self, existing=False, already_posted=False, issues=None, expected_code=0):
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
                if issues is not None:
                    return issues
                return [{"number": 55, "html_url": "https://github.com/owner/repo/issues/55",
                         "user": {"login": "github-actions[bot]"},
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
                mock.patch.object(recovery, "write", side_effect=write), \
                mock.patch.object(sys, "stderr", new_callable=io.StringIO) as diagnostic, \
                mock.patch.object(sys, "argv", [str(MODULE), "--escalate", "owner/repo", "7"]):
            code = recovery.main()
        self.assertEqual(code, expected_code)
        self.last_escalation_diagnostic = diagnostic.getvalue()
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

    def parser_work(self, number, login=None, **extra):
        issue = dict(number=number, html_url=f"https://github.com/owner/repo/issues/{number}",
                     body="<!-- mergepath-coderabbit-parser-drift:v1 -->\nExisting work", **extra)
        if login is not None:
            issue["user"] = {"login": login}
        return issue

    def test_unrelated_marker_authors_cannot_capture_parser_work(self):
        for login in (None, "unrelated-user", "nathanpayne-claude", "another[bot]"):
            with self.subTest(login=login):
                posts = self.exercise(issues=[self.parser_work(88, login)])
                self.assertEqual([path for path, _ in posts],
                                 ["repos/owner/repo/issues", "repos/owner/repo/issues/7/comments"])
                self.assertIn("issues/55", posts[-1][1]["body"])

    def test_unrelated_markers_do_not_make_one_actions_work_item_ambiguous(self):
        posts = self.exercise(issues=[self.parser_work(88, "unrelated-user"),
                                     self.parser_work(55, "github-actions[bot]")])
        self.assertEqual([path for path, _ in posts],
                         ["repos/owner/repo/issues/55/comments", "repos/owner/repo/issues/7/comments"])

    def test_unreadable_author_cannot_capture_parser_work(self):
        for user in (None, "github-actions[bot]"):
            with self.subTest(user=user):
                issue = self.parser_work(88)
                issue["user"] = user
                posts = self.exercise(issues=[issue])
                self.assertEqual([path for path, _ in posts],
                                 ["repos/owner/repo/issues", "repos/owner/repo/issues/7/comments"])

    def test_multiple_actions_work_items_remain_ambiguous(self):
        posts = self.exercise(issues=[self.parser_work(55, "github-actions[bot]"),
                                     self.parser_work(56, "github-actions[bot]")], expected_code=3)
        self.assertFalse(posts)
        self.assertIn("ambiguous parser-drift work item", self.last_escalation_diagnostic)
        self.assertIn("PR #7", self.last_escalation_diagnostic)

    def test_actions_pull_request_marker_does_not_capture_parser_work(self):
        posts = self.exercise(issues=[self.parser_work(88, "github-actions[bot]",
                                                     pull_request={"url": "https://api.github.com/repos/owner/repo/pulls/88"}),
                                     self.parser_work(55, "github-actions[bot]")])
        self.assertEqual([path for path, _ in posts],
                         ["repos/owner/repo/issues/55/comments", "repos/owner/repo/issues/7/comments"])


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

    def test_dispatch_recheck_issue_comment_binds_the_commented_pr(self):
        # #2881: on issue_comment the PR is the commented issue, never the
        # (absent) dispatch payload, and the published head comes from the
        # open-PR list. A commented PR that is not open publishes nothing.
        step = self.workflow_step("merge-clearance-gate.yml", "dispatch-recheck",
                                  "output=$(scripts/merge-clearance-gate.sh")
        for commented, expected_rc, writes in (("7", 0, [["POST", 1], ["PATCH", 1]]), ("8", 1, [])):
            with self.subTest(commented=commented):
                (self.path / "state.json").write_text(json.dumps(
                    dict(runs=[], writes=[], head=HEAD, revision=REVISION, heads=[7])))
                self.env.update(EVENT_NAME="issue_comment", PR="", PR_COMMENTED=commented,
                                CHECK_NAME="Merge clearance gate")
                result = self.shell(step)
                self.assertEqual(result.returncode, expected_rc, result.stdout + result.stderr)
                self.assertEqual(self.state()["writes"], writes)
                if writes:
                    self.assertEqual(self.state()["runs"][0]["head_sha"], HEAD)
                    self.assertEqual(self.state()["evaluated"], [1])

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
