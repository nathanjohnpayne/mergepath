"""Hermetic author telemetry: no remote API, cache or real credential accesses."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from mergepath.cockpit import author_budget as A
from mergepath.cockpit.github import ClientError, GitHubClient, Response
from mergepath.cockpit.inventory import Repository
from mergepath.cockpit.scheduler import Sample, Scheduler
from mergepath.cockpit.server import Application

NOW = 1700000000
TOKEN = "fixture_author_private"
BODY = {"data": {"viewer": {"login": A.AUTHOR}, "rateLimit": {"limit": 5000, "remaining": 4990, "used": 10, "resetAt": "2023-11-14T23:13:20Z"}}}
HEADERS = {"X-RateLimit-Resource": "graphql", "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4800", "X-RateLimit-Used": "200", "X-RateLimit-Reset": str(NOW + 3600)}


class AuthorBudgetTests(unittest.TestCase):
    def measure(self, response=None, *, exports=None, code=0, body_failure=False):
        calls, commands = [], []
        class Cache:
            def __init__(self, deadline):
                self.deadline = deadline
            def run(self, command, root, env, **kwargs):
                commands.append((command, root, env, kwargs, self.deadline))
                return code, exports if exports is not None else b"export OP_PREFLIGHT_AUTHOR_PAT='fixture_author_private'\nunset OP_PREFLIGHT_PARENT_PID\nexport GH_TOKEN='ignored_reviewer'\n"
        def transport(method, url, headers, body, timeout):
            calls.append((method, url, headers, json.loads(body), timeout))
            if body_failure:
                raise ClientError("response_too_large", response=response)
            return response or Response(200, HEADERS, json.dumps(BODY).encode())
        result = A.measure(ROOT, "/fixture/cache", "codex", {"PATH": "/usr/bin:/bin"}, time.monotonic() + 10,
                           runner_factory=Cache, clock=lambda: NOW,
                           client_factory=lambda token, **kw: GitHubClient(token, transport=transport, clock=lambda: NOW, **kw))
        return result, calls, commands

    def test_fixed_query_identity_headers_and_inert_cached_exports(self):
        result, calls, commands = self.measure()
        self.assertEqual(len(calls), 1)
        method, url, headers, body, timeout = calls[0]
        self.assertEqual((method, url, body), ("POST", "https://api.github.com/graphql", {"query": A.QUERY, "variables": {}}))
        self.assertEqual(headers["Authorization"], "Bearer " + TOKEN)
        self.assertLessEqual(timeout, 10)
        self.assertEqual(commands[0][0][-6:], ["--agent", "codex", "--mode", "review", "--check", "--print-exports"])
        self.assertEqual(commands[0][3], {"limit": 65536})
        self.assertEqual(result["verified_identity"], A.AUTHOR)
        row = result["budgets"]["graphql"]
        self.assertEqual((row["remaining"], row["used"]), (4800, 200))
        self.assertEqual(row["credential_source"], "OP_PREFLIGHT_AUTHOR_PAT")
        self.assertNotIn(TOKEN, json.dumps(result)); self.assertNotIn("ignored_reviewer", json.dumps(result))

    def test_missing_duplicate_malformed_cache_refuses_without_network(self):
        for exports in (b"", b"export OP_PREFLIGHT_AUTHOR_PAT=x\nexport OP_PREFLIGHT_AUTHOR_PAT=y\n",
                        b"export OP_PREFLIGHT_AUTHOR_PAT='$(touch /never)'\n", b"export OP_PREFLIGHT_AUTHOR_PAT\n", b"\xff"):
            with self.subTest(exports=exports):
                result, calls, _ = self.measure(exports=exports)
                self.assertEqual(result["error"], "cached_author_required"); self.assertEqual(calls, [])
        result, calls, _ = self.measure(code=1)
        self.assertEqual(result["error"], "cached_author_required"); self.assertEqual(calls, [])

    def test_viewer_mismatch_refuses_all_other_account_evidence(self):
        body = json.loads(json.dumps(BODY)); body["data"]["viewer"]["login"] = "nathanpayne-codex"
        result, _, _ = self.measure(Response(200, HEADERS, json.dumps(body).encode()))
        self.assertEqual(result["error"], "author_identity_mismatch"); self.assertEqual(result["budgets"], {})
        self.assertIsNone(result["verified_identity"])

    def test_denial_http200_exhaustion_and_body_failure_preserve_header_evidence(self):
        for status, body in ((403, b'{}'), (200, b'{"errors":[{"message":"denied"}]}')):
            with self.subTest(status=status):
                result, _, _ = self.measure(Response(status, {**HEADERS, "X-RateLimit-Remaining": "0"}, body))
                self.assertEqual(result["error"], "primary_exhausted"); self.assertTrue(result["stale"])
                self.assertEqual(result["budgets"]["graphql"]["remaining"], 0)
                self.assertIsNone(result["verified_identity"])
        result, _, _ = self.measure(Response(200, HEADERS, b""), body_failure=True)
        self.assertEqual(result["error"], "response_too_large")
        self.assertEqual(result["budgets"]["graphql"]["remaining"], 4800)

    def test_secondary_200_and_retry_after_never_leak_error_body(self):
        for response in (Response(403, {**HEADERS, "Retry-After": "180"}, b'private diagnostic'),
                         Response(200, HEADERS, b'{"errors":[{"message":"secondary rate limit secret"}]}')):
            with self.subTest(status=response.status):
                result, _, _ = self.measure(response)
                self.assertEqual(result["error"], "secondary_limit")
                self.assertTrue(result["budgets"]["graphql"]["secondary_limited"])
                self.assertNotIn("secret", json.dumps(result)); self.assertNotIn("private diagnostic", json.dumps(result))

    def test_valid_query_fields_fill_missing_headers_only(self):
        result, _, _ = self.measure(Response(200, {}, json.dumps(BODY).encode()))
        self.assertEqual(result["budgets"]["graphql"]["remaining"], 4990)
        bad = json.loads(json.dumps(BODY)); bad["data"]["rateLimit"]["remaining"] = 9000
        result, _, _ = self.measure(Response(200, {}, json.dumps(bad).encode()))
        self.assertEqual(result["error"], "invalid_upstream_json")
        self.assertIsNone(result["budgets"]["graphql"]["remaining"])

    def test_public_boundary_refuses_unknown_fields_and_invalid_scalars(self):
        good, _, _ = self.measure()
        for field, value in (("token", TOKEN), ("error", TOKEN), ("verified_identity", "other")):
            bad = json.loads(json.dumps(good)); bad[field] = value
            with self.subTest(field=field), self.assertRaises((ValueError, TypeError)):
                A.public_sample(bad)
        for field, value in (("limit", True), ("remaining", float('inf')), ("identity_evidence", TOKEN)):
            bad = json.loads(json.dumps(good)); bad["budgets"]["graphql"][field] = value
            with self.subTest(field=field), self.assertRaises((ValueError, TypeError)):
                A.public_sample(bad)

    def test_parent_public_output_cap_and_malformed_data_are_stable_refusals(self):
        provider = A.AuthorBudgetProvider(ROOT, '/fixture/cache', 'codex')
        self.addCleanup(provider.close)
        original = A.subprocess.Popen
        for text in ('private raw diagnostics', 'x' * (A.MAX_PUBLIC + 1), json.dumps({**A.empty_sample(), 'token': TOKEN})):
            with self.subTest(size=len(text)):
                def fake(command, **kwargs):
                    return original([sys.executable, '-I', '-c', 'import sys; sys.stdout.write(sys.argv[1])', text], **kwargs)
                with patch.object(A.subprocess, 'Popen', side_effect=fake):
                    value = provider._read(time.monotonic() + 2)
                self.assertEqual(value['error'], 'worker_protocol_error')
                self.assertNotIn('private raw', json.dumps(value)); self.assertNotIn(TOKEN, json.dumps(value))
                self.assertIsNone(provider._process)

    def test_repeated_secondary_failures_back_off_and_success_replaces_only_author_state(self):
        now = [NOW]
        provider = A.AuthorBudgetProvider(ROOT, '/fixture/cache', 'codex', clock=lambda: now[0])
        self.addCleanup(provider.close)
        secondary, _, _ = self.measure(Response(403, HEADERS, b'secondary rate limit'))
        success, _, _ = self.measure()
        with patch.object(provider, '_read', side_effect=[secondary, secondary, secondary, success]) as read:
            for delay in (60, 120, 240):
                value = provider.fetch(time.monotonic() + 1).data
                self.assertEqual(value['retry_at'], now[0] + delay)
                now[0] += delay - 1; provider.fetch(time.monotonic() + 1)
                self.assertEqual(read.call_count, (60, 120, 240).index(delay) + 1)
                now[0] += 1
            value = provider.fetch(time.monotonic() + 1).data
            self.assertIsNone(value['error']); self.assertFalse(value['stale'])
            self.assertEqual(value['retry_at'], now[0] + 60); self.assertEqual(provider._failures, 0)

    def test_parent_reset_backoff_persists_without_pausing_reviewer(self):
        now = [NOW]
        provider = A.AuthorBudgetProvider(ROOT, "/fixture/cache", "codex", clock=lambda: now[0])
        self.addCleanup(provider.close)
        exhausted, _, _ = self.measure(Response(403, {**HEADERS, "X-RateLimit-Remaining": "0"}, b'{}'))
        reviewer = GitHubClient("fixture_reviewer", transport=lambda *args: Response(200, HEADERS, b'{}'), clock=lambda: NOW)
        with patch.object(provider, "_read", return_value=exhausted) as read:
            first = provider.fetch(time.monotonic() + 1).data
            now[0] += 60; provider.fetch(time.monotonic() + 1)
            self.assertEqual(read.call_count, 1); self.assertEqual(first["retry_at"], NOW + 3600)
            self.assertEqual(reviewer.get("/repos/a/b"), {})
            now[0] = NOW + 3601; provider.fetch(time.monotonic() + 1)
            self.assertEqual(read.call_count, 2)

    def test_secondary_backoff_failure_retains_original_observation_and_identity(self):
        now = [NOW]
        provider = A.AuthorBudgetProvider(ROOT, "/fixture/cache", "codex", clock=lambda: now[0])
        self.addCleanup(provider.close)
        success, _, _ = self.measure()
        secondary, _, _ = self.measure(Response(403, {**HEADERS, "Retry-After": "180"}, b'{}'))
        with patch.object(provider, "_read", side_effect=[success, A.empty_sample("cached_author_required"), secondary]) as read:
            provider.fetch(time.monotonic() + 1); now[0] += 61
            denied = provider.fetch(time.monotonic() + 1).data
            self.assertEqual(denied["budgets"]["graphql"]["observed_at"], NOW)
            self.assertEqual(denied["identity_evidence"], "last_viewer_verified")
            self.assertTrue(denied["stale"]); now[0] += 61
            throttled = provider.fetch(time.monotonic() + 1).data
            self.assertEqual(throttled["retry_at"], now[0] + 180)
            now[0] += 120; provider.fetch(time.monotonic() + 1); self.assertEqual(read.call_count, 3)

    def test_real_child_missing_cache_suppresses_stderr_and_does_not_read_ambient_tokens(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'scripts').mkdir()
            (root / 'scripts/op-preflight.sh').write_text('printf "PRIVATE stderr" >&2\nprintf "export OP_PREFLIGHT_REVIEWER_PAT=private_reviewer\\n"\nexit 1\n')
            provider = A.AuthorBudgetProvider(root, root / 'unused-cache', "codex")
            self.addCleanup(provider.close)
            with patch.dict(os.environ, {"GH_TOKEN": TOKEN, "OP_PREFLIGHT_AUTHOR_PAT": TOKEN, "HTTPS_PROXY": "secret", "PYTHONPATH": "secret"}):
                env = provider._environment()
                self.assertFalse(set(env) & {"GH_TOKEN", "OP_PREFLIGHT_AUTHOR_PAT", "HTTPS_PROXY", "PYTHONPATH"})
                result = provider.fetch(time.monotonic() + 2).data
            self.assertEqual(result["error"], "cached_author_required")
            self.assertNotIn("PRIVATE", json.dumps(result)); self.assertNotIn(TOKEN, json.dumps(result))
            self.assertIsNone(provider._process)
            self.assertEqual(provider.workspace.stat().st_mode & 0o777, 0o700)

    def test_parent_deadline_and_close_reap_process_and_remove_workspace(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'scripts').mkdir()
            marker = root / 'must-not-survive'
            (root / 'scripts/op-preflight.sh').write_text('sleep .5\nprintf survived > ' + str(marker) + '\n')
            provider = A.AuthorBudgetProvider(root, root / 'cache', "codex")
            start = time.monotonic(); result = provider.fetch(start + .15).data
            self.assertEqual(result["error"], "deadline_exceeded"); self.assertLess(time.monotonic() - start, 1)
            provider._blocked = 0
            thread = threading.Thread(target=lambda: provider.fetch(time.monotonic() + 5)); thread.start()
            for _ in range(100):
                if provider._process is not None: break
                time.sleep(.005)
            workspace = provider.workspace; process = provider._process
            provider.close(); thread.join(1)
            self.assertFalse(thread.is_alive()); self.assertIsNotNone(process.poll()); self.assertFalse(workspace.exists())
            time.sleep(.55); self.assertFalse(marker.exists())

    def test_read_reap_failure_still_closes_both_pipes_and_releases_slot(self):
        # Reap the real synthetic child first, then inject the cleanup failure;
        # this verifies bookkeeping without leaving an orphan or relaxing waits.
        original_popen = A.subprocess.Popen
        for error in (subprocess.TimeoutExpired('fixture-reap', 2), RuntimeError('fixture-unrelated')):
            with self.subTest(error=type(error).__name__):
                provider = A.AuthorBudgetProvider(ROOT, '/fixture/cache', 'codex')
                self.addCleanup(provider.close)
                captured = []
                def spawn(command, **kwargs):
                    return original_popen([sys.executable, '-I', '-c', 'print(' + repr(json.dumps(A.empty_sample())) + ')'], **kwargs)
                def failed_reap(process):
                    A.AuthorBudgetProvider._kill(process)
                    captured.append(process)
                    raise error
                with patch.object(A.subprocess, 'Popen', side_effect=spawn), patch.object(provider, '_kill', side_effect=failed_reap):
                    with self.assertRaises(type(error)) as raised:
                        provider._read(time.monotonic() + 2)
                self.assertIs(raised.exception, error)
                process = captured[0]
                self.assertIsNotNone(process.poll())  # The injection itself is safe.
                self.assertTrue(process.stdout.closed); self.assertTrue(process.stderr.closed)
                self.assertIsNone(provider._process)

    def test_close_reap_failure_still_removes_workspace_and_preserves_failure(self):
        for error in (subprocess.TimeoutExpired('fixture-reap', 2), RuntimeError('fixture-unrelated')):
            with self.subTest(error=type(error).__name__):
                provider = A.AuthorBudgetProvider(ROOT, '/fixture/cache', 'codex')
                self.addCleanup(provider.close)
                process = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(30)'],
                                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                provider._process = process
                workspace = provider.workspace
                def failed_reap(child):
                    A.AuthorBudgetProvider._kill(child)
                    raise error
                try:
                    with patch.object(provider, '_kill', side_effect=failed_reap):
                        with self.assertRaises(type(error)) as raised:
                            provider.close()
                    self.assertIs(raised.exception, error)
                    self.assertIsNotNone(process.poll())  # Not proof a stuck child can be reaped.
                    self.assertTrue(provider._closed); self.assertFalse(workspace.exists())
                finally:
                    A.AuthorBudgetProvider._kill(process)
                    process.stdout.close(); process.stderr.close()

    def test_workspace_refusal_is_independent_and_shared_scheduler_preserves_sources(self):
        with patch.object(A.tempfile, "mkdtemp", side_effect=PermissionError()):
            provider = A.AuthorBudgetProvider(ROOT, '/fixture/cache', 'codex')
        self.addCleanup(provider.close)
        self.assertEqual(provider.fetch(time.monotonic() + 1).data['error'], 'upstream_unavailable')
        scheduler = Scheduler()
        self.addCleanup(scheduler.close)
        scheduler.register('api_author', provider.fetch, hot_interval=60, idle_interval=60, timeout=20)
        scheduler.register('prs', lambda deadline: Sample({'rows': ['intact']}))
        scheduler.tick()
        for _ in range(100):
            if not any(x['in_flight'] for x in scheduler.snapshot().values()): break
            time.sleep(.005)
        self.assertEqual(scheduler.snapshot()['prs']['data'], {'rows': ['intact']})
        self.assertEqual(scheduler.snapshot()['api_author']['data']['error'], 'upstream_unavailable')

    def test_runtime_close_closes_author_provider_without_credential_expansion(self):
        client = GitHubClient('fixture_reviewer')
        app = Application((Repository('hub', 'owner/hub', True),), client)
        provider = A.AuthorBudgetProvider(ROOT, '/fixture/cache', 'cursor')
        workspace = provider.workspace; app.api_author = provider
        app.scheduler.register('api_author', lambda deadline: Sample(A.empty_sample('permission_denied')),
                               hot_interval=60, idle_interval=60, timeout=20)
        self.assertEqual(app.snapshot()['api_budget'], {})
        self.assertEqual(app.snapshot()['sources']['api_author']['error'], 'unavailable')
        self.assertNotIn('fixture_reviewer', json.dumps(app.snapshot()))
        app.close(); self.assertFalse(workspace.exists())


if __name__ == '__main__':
    unittest.main()
