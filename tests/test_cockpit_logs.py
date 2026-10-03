"""Hermetic Actions log authority and shared budget/deadline coverage."""

import sys
import http.client
import json
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mergepath.cockpit.github import (ClientError, GitHubClient, MAX_BODY, Response,
                                     actions_log_transport, http_transport)
from mergepath.cockpit.ci import LogExcerptCache
from mergepath.cockpit.inventory import Repository
from mergepath.cockpit.scheduler import Sample
from mergepath.cockpit.server import Application, CockpitServer

LOCATION = "https://productionresultssa19.blob.core.windows.net/logs/job.txt?sig=fixture-secret"
TOKEN = "fixture-reviewer-only"


class LogTests(unittest.TestCase):
    def client(self, *, status=302, location=LOCATION, headers=None, download=None):
        self.api, self.downloads = [], []
        def transport(*args):
            self.api.append(args)
            return Response(status, {"Location": location, "X-RateLimit-Remaining": "4900", **(headers or {})}, b"")
        def logs(*args):
            self.downloads.append(args)
            return download or Response(200, {}, b"observed complete log\nFAIL last\n")
        return GitHubClient(TOKEN, transport=transport, log_transport=logs)

    def test_typed_read_accounts_api_headers_without_caching_location_or_log(self):
        client = self.client()
        result = client.read_job_log("owner/repo", "123")
        self.assertEqual(result, b"observed complete log\nFAIL last\n")
        self.assertEqual(self.api[0][0:2], ("GET", "https://api.github.com/repos/owner/repo/actions/jobs/123/logs"))
        self.assertEqual(self.api[0][2]["Authorization"], "Bearer " + TOKEN)
        self.assertEqual(self.downloads[0][0], LOCATION)
        self.assertEqual(len(self.downloads[0]), 2)
        self.assertEqual(client.budget()["core"]["remaining"], 4900)
        self.assertEqual(client._cache, {})
        self.assertNotIn("fixture-secret", str(client.budget()))

    def test_generic_json_get_never_follows_redirect(self):
        client = self.client()
        with self.assertRaisesRegex(ClientError, "upstream_http_error"):
            client.get("/repos/owner/repo/actions/jobs/123/logs")
        self.assertEqual(self.downloads, [])

    def test_identifiers_are_typed_before_any_request(self):
        client = self.client()
        for repo, job in [("../repo", "1"), ("owner/..", "1"), ("owner/repo?x", "1"),
                          ("owner/repo", 123), ("owner/repo", "0"), ("owner/repo", "1/logs"),
                          ("owner/repo", "1" * 21)]:
            with self.subTest(repo=repo, job=job), self.assertRaisesRegex(ClientError, "invalid_endpoint"):
                client.read_job_log(repo, job)
        self.assertEqual(self.api, [])

    def test_signed_destination_allowlist_rejects_authority_escapes_before_download(self):
        for location in [None, "", "http://productionresultssa19.blob.core.windows.net/a",
                         "https://evil.example/a", LOCATION.replace(".net", ".net.evil.example"),
                         LOCATION.replace("https://", "https://user@"), LOCATION.replace(".net", ".net:443"),
                         LOCATION + "#fragment", LOCATION + "\n", "https://[invalid",
                         "https://127.0.0.1/a", "https://productionresultssa.blob.core.windows.net/a"]:
            client = self.client(location=location)
            with self.subTest(location=location), self.assertRaises(ClientError) as caught:
                client.read_job_log("owner/repo", "123")
            self.assertEqual(caught.exception.category, "invalid_endpoint")
            self.assertIsNone(caught.exception.response)
            self.assertEqual(self.downloads, [])
            self.assertEqual(client.budget()["core"]["remaining"], 4900)

    def test_real_download_transport_is_credential_free_and_generic_transport_stays_fixed(self):
        with patch("mergepath.cockpit.github._https_transport", return_value=Response(200, {}, b"")) as transport:
            actions_log_transport(LOCATION, 3)
            method, parts, headers, body, timeout = transport.call_args.args
            self.assertEqual(method, "GET"); self.assertEqual(timeout, 3)
            self.assertEqual(parts.netloc, "productionresultssa19.blob.core.windows.net")
            self.assertEqual(set(headers), {"User-Agent", "Accept", "Accept-Encoding"})
            self.assertIsNone(body)
            with self.assertRaisesRegex(ClientError, "invalid_endpoint"):
                http_transport("GET", LOCATION, {"Authorization": TOKEN}, None, 3)
            self.assertEqual(transport.call_count, 1)

    def test_download_redirect_or_oversize_returns_no_partial_bytes(self):
        for download, expected in [(Response(302, {"Location": "https://evil.example"}, b""), "upstream_http_error"),
                                   (Response(200, {}, b"x" * (MAX_BODY + 1)), "response_too_large")]:
            client = self.client(download=download)
            with self.assertRaisesRegex(ClientError, expected):
                client.read_job_log("owner/repo", "123")
            self.assertEqual(len(self.downloads), 1)
            self.assertEqual(client._cache, {})

    def test_shared_throttle_and_reserve_prevent_log_dispatch(self):
        for headers, expected in [({"Retry-After": "60"}, "upstream_backoff"),
                ({"X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "99",
                  "X-RateLimit-Reset": str(int(time.time()) + 300)}, "primary_reserve")]:
            client = self.client(status=403 if "Retry-After" in headers else 302, headers=headers)
            try:
                client.read_job_log("owner/repo", "123")
            except ClientError:
                pass
            with self.assertRaisesRegex(ClientError, expected):
                client.read_job_log("owner/repo", "123")
            self.assertEqual(len(self.api), 1)

    def test_late_download_is_discarded_and_does_not_replace_api_budget(self):
        client = self.client()
        def late(*args):
            time.sleep(0.02)
            return Response(200, {"X-RateLimit-Remaining": "1"}, b"late")
        client._log_transport = late
        with self.assertRaisesRegex(ClientError, "deadline_exceeded"):
            client.read_job_log("owner/repo", "123", deadline=time.monotonic() + 0.005)
        self.assertEqual(client.budget()["core"]["remaining"], 4900)

    def test_log_download_occupies_shared_transport_fence(self):
        client = self.client()
        entered, release = threading.Event(), threading.Event()
        def download(*args):
            entered.set(); release.wait(1)
            return Response(200, {}, b"complete")
        client._log_transport = download
        thread = threading.Thread(target=client.read_job_log, args=("owner/repo", "123"), daemon=True)
        thread.start()
        try:
            self.assertTrue(entered.wait(1))
            with self.assertRaisesRegex(ClientError, "deadline_exceeded"):
                client.get("/repos/owner/repo/pulls", deadline=time.monotonic() + 0.02)
            self.assertEqual(len(self.api), 1)
            self.assertEqual(client.budget()["core"]["remaining"], 4900)
        finally:
            release.set(); thread.join(1)

    def test_download_errors_drop_private_message_and_response_metadata(self):
        client = self.client()
        for exception in [RuntimeError(LOCATION), ClientError("upstream_unavailable", response=Response(302, {"Location": LOCATION}, b""))]:
            def fail(*args):
                raise exception
            client._log_transport = fail
            with self.assertRaises(ClientError) as caught:
                client.read_job_log("owner/repo", "123")
            self.assertEqual(str(caught.exception), "upstream_unavailable")
            self.assertIsNone(caught.exception.response)


class ExcerptHTTPTests(unittest.TestCase):
    def test_actual_handler_auth_observed_identity_redaction_and_no_duplicate_reads(self):
        inventory = (Repository("repo", "owner/repo", True),)
        client = GitHubClient(TOKEN, transport=lambda *args: self.fail("unexpected upstream request"))
        app = Application(inventory, client)
        reads = []
        def read_log(repo, job, deadline):
            reads.append((repo, job, deadline))
            return ("FAIL: " + TOKEN + app._session + " <script>literal</script>\n").encode()
        app.ci_excerpts = LogExcerptCache(inventory, read_log)
        step = {"number": "2", "conclusion": "failure", "started_at": None, "completed_at": None}
        data = {"schema": "ci/v1", "repositories": [{"repo": "owner/repo", "stale": False}],
                "runs": [{"repo": "owner/repo", "id": "10", "attempt": "1", "jobs": [{"id": "123", "steps": [step]}]}]}
        app.scheduler.register("ci", lambda deadline: Sample(data))
        app.register_panel("ci", "ci")
        app.scheduler.start()
        end = time.monotonic() + 1
        while app.panel_snapshot("ci")["envelope"]["data"] is None and time.monotonic() < end:
            time.sleep(0.002)
        server = CockpitServer(app)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        port = server.server_address[1]
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        def request(path, cookie=None):
            connection.request("GET", path, headers={"Cookie": cookie} if cookie else {})
            reply = connection.getresponse(); body = reply.read()
            return reply.status, json.loads(body)
        path = app.scope_path + "api/ci/excerpt?repo=owner%2Frepo&run=10&attempt=1&job=123&step=2"
        try:
            self.assertEqual(request(path)[0], 401)
            self.assertEqual(request("/api/ci/excerpt")[0], 404)
            connection.request("POST", "/api/bootstrap", headers={"Origin": f"http://127.0.0.1:{port}",
                "X-Cockpit-Bootstrap": app._nonce, "X-Cockpit-CSRF": app._nonce})
            reply = connection.getresponse()
            self.assertEqual(reply.status, 204)
            cookies = [value for name, value in reply.getheaders() if name.lower() == "set-cookie"]
            cookie = cookies[-1].split(";", 1)[0]; reply.read()
            for bad in [path + "&job=123", path + "&url=https://evil.example", path.replace("job=123", "job=124"),
                        path.replace("owner%2Frepo", "other%2Frepo")]:
                self.assertEqual(request(bad, cookie)[0], 400)
            self.assertEqual(reads, [])
            for _ in range(2):
                status, payload = request(path, cookie)
                self.assertEqual(status, 200)
                self.assertEqual(payload["status"], "ok")
                self.assertEqual(payload["scope"], "job")
                self.assertNotIn(TOKEN, str(payload)); self.assertNotIn(app._session, str(payload))
                self.assertIn("<script>literal</script>", payload["lines"][0])
            self.assertEqual(len(reads), 1)
            self.assertEqual(reads[0][:2], ("owner/repo", "123"))
        finally:
            connection.close(); app.close(); server.shutdown(); server.server_close(); thread.join(1)


if __name__ == "__main__":
    unittest.main()
