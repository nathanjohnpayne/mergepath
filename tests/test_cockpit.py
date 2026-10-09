"""Hermetic foundation coverage; remote sockets and real credentials are forbidden."""

import contextlib
import http.client
import http.cookiejar
import hashlib
import importlib
import io
import json
import math
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from mergepath.cockpit.author_budget import empty_sample as empty_author_sample
from mergepath.cockpit.github import ClientError, GitHubClient, MAX_BODY, ORIGIN, Response, copy_json_tree, http_transport
from mergepath.cockpit.inventory import HUB, Repository, load_inventory
from mergepath.cockpit.scheduler import Sample, Scheduler
from mergepath.cockpit.server import Application, COOKIE, CSP, CockpitServer


TOKEN = "fixture-reviewer-credential"


def author_fixture():
    return SimpleNamespace(fetch=lambda deadline: Sample(empty_author_sample("cached_author_required")), close=lambda: None)


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class HTTPFixture:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, method, url, headers, body, timeout):
        self.calls.append((method, url, headers.copy(), body, timeout))
        if not self.responses:
            raise AssertionError("fixture exhausted; no remote fallback permitted")
        reply = self.responses.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def reply(status=200, data=None, **headers):
    return Response(status, headers, json.dumps(data).encode() if data is not None else b"")


def wait_until(predicate, timeout=1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.002)
    raise AssertionError("bounded fixture wait expired")


class ClientTests(unittest.TestCase):
    def client(self, fixture, clock=None, **kwargs):
        clock = clock or Clock()
        return GitHubClient(TOKEN, transport=fixture, clock=clock, monotonic=clock, **kwargs)

    def test_etag_reuse_and_real_304_budget(self):
        fixture = HTTPFixture(
            reply(data=[{"id": 1}], ETag='"first"', **{
                "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4997", "X-RateLimit-Used": "3",
                "X-RateLimit-Reset": "2000", "X-RateLimit-Resource": "core"}),
            reply(304, **{"x-ratelimit-limit": "5000", "x-ratelimit-remaining": "4996",
                         "x-ratelimit-used": "4", "x-ratelimit-reset": "2000"}),
        )
        client = self.client(fixture)
        self.assertEqual(client.get("/repos/a/b/pulls"), [{"id": 1}])
        self.assertEqual(client.get("/repos/a/b/pulls"), [{"id": 1}])
        self.assertEqual(fixture.calls[1][2]["If-None-Match"], '"first"')
        self.assertEqual(client.budget()["core"]["remaining"], 4996)
        self.assertEqual(client.budget()["core"]["status"], 304)
        self.assertEqual(fixture.calls[0][2]["Authorization"], "Bearer " + TOKEN)

    def test_pagination_reuses_each_cached_link_and_page(self):
        next_link = '<https://api.github.com/repos/a/b/pulls?page=2>; rel="next"'
        fixture = HTTPFixture(reply(data=[1], ETag="one", Link=next_link), reply(data=[2], ETag="two"),
                              reply(304), reply(304))
        client = self.client(fixture)
        self.assertEqual(client.pages("/repos/a/b/pulls"), [1, 2])
        self.assertEqual(client.pages("/repos/a/b/pulls"), [1, 2])
        self.assertEqual([call[2].get("If-None-Match") for call in fixture.calls], [None, None, "one", "two"])

    def test_pagination_refuses_escape_cycle_and_truncation(self):
        for url, category in [("https://evil.example/repos/a/b/pulls?page=2", "invalid_next_link"),
                              ("https://api.github.com/repos/a/b/issues?page=2", "invalid_next_link"),
                              ("https://api.github.com/repos/a/b/pulls", "invalid_next_link")]:
            with self.subTest(url=url):
                client = self.client(HTTPFixture(reply(data=[], Link=f'<{url}>; rel="next"')))
                with self.assertRaisesRegex(ClientError, category):
                    client.pages("/repos/a/b/pulls")
        repeated = '<https://api.github.com/repos/a/b/pulls?page=2>; rel="next"'
        with self.assertRaisesRegex(ClientError, "pagination_cycle"):
            self.client(HTTPFixture(reply(data=[], Link=repeated), reply(data=[], Link=repeated))).pages("/repos/a/b/pulls")
        client = self.client(HTTPFixture(reply(data=[], Link='<https://api.github.com/repos/a/b/pulls?page=2>; rel="next"')))
        with self.assertRaisesRegex(ClientError, "page_limit"):
            client.pages("/repos/a/b/pulls", max_pages=1)

    def test_pagination_follows_the_repository_alias_of_the_same_endpoint(self):
        # Observed 2026-10-06: GitHub paginates /repos/<owner>/<repo>/actions/runs through
        # /repositories/<id>/actions/runs, and every enrolled repository has several pages.
        alias = "https://api.github.com/repositories/1190939344/actions/runs?per_page=100&created=%3E%3D2026-10-05T15%3A15%3A04Z&page="
        fixture = HTTPFixture(reply(data={"workflow_runs": [1]}, Link=f'<{alias}2>; rel="next", <{alias}9>; rel="last"'),
                              reply(data={"workflow_runs": [2]}, Link=f'<{alias}3>; rel="next"'),
                              reply(data={"workflow_runs": [3]}))
        client = self.client(fixture)
        self.assertEqual(client.pages("/repos/a/b/actions/runs?per_page=100&created=%3E%3D2026-10-05T15%3A15%3A04Z",
                                      collection="workflow_runs"), [1, 2, 3])
        # The alias never leaves the client: later pages still request the enrolled /repos/ endpoint.
        self.assertEqual([call[1] for call in fixture.calls][1:],
                         [ORIGIN + "/repos/a/b/actions/runs?per_page=100&created=%3E%3D2026-10-05T15%3A15%3A04Z&page=" + page for page in "23"])
        dropped = HTTPFixture(reply(data=[], Link='<https://api.github.com/repositories/1190939344/actions/runs?page=2>; rel="next"'))
        with self.assertRaisesRegex(ClientError, "invalid_next_link"):
            self.client(dropped).pages("/repos/a/b/actions/runs?per_page=100&status=queued")
        # Only the page cursor is taken from a link: an added or altered filter never reaches the next request.
        widened = HTTPFixture(reply(data=[1], Link='<https://api.github.com/repositories/1190939344/actions/runs?per_page=100&status=queued&status=completed&per_page=1&page=2>; rel="next"'),
                              reply(data=[2]))
        self.assertEqual(self.client(widened).pages("/repos/a/b/actions/runs?per_page=100&status=queued"), [1, 2])
        self.assertEqual(widened.calls[1][1], ORIGIN + "/repos/a/b/actions/runs?per_page=100&status=queued&page=2")
        for query in ["per_page=100&status=queued", "per_page=100&status=queued&page=0", "per_page=100&status=queued&page=2&page=3", "per_page=100&status=queued&page=x"]:
            with self.subTest(query=query), self.assertRaisesRegex(ClientError, "invalid_next_link"):
                self.client(HTTPFixture(reply(data=[], Link=f'<https://api.github.com/repos/a/b/actions/runs?{query}>; rel="next"'))).pages("/repos/a/b/actions/runs?per_page=100&status=queued")
        for url in ["https://api.github.com/repositories/1190939344/pulls?page=2",
                    "https://api.github.com/repositories/1190939344/actions/runs/7/jobs?page=2",
                    "https://api.github.com/repositories/abc/actions/runs?page=2",
                    "https://api.github.com/repositories/01/actions/runs?page=2",
                    "https://api.github.com/repositories/1190939344/actions/runs?page=2#frag"]:
            with self.subTest(url=url), self.assertRaisesRegex(ClientError, "invalid_next_link"):
                self.client(HTTPFixture(reply(data={"workflow_runs": []}, Link=f'<{url}>; rel="next"'))).pages(
                    "/repos/a/b/actions/runs", collection="workflow_runs")
        drifting = HTTPFixture(reply(data=[1], Link=f'<{alias}2>; rel="next"'),
                               reply(data=[2], Link='<https://api.github.com/repositories/2/actions/runs?page=3>; rel="next"'))
        with self.assertRaisesRegex(ClientError, "invalid_next_link"):
            self.client(drifting).pages("/repos/a/b/actions/runs")

    def test_object_collection_pagination(self):
        client = self.client(HTTPFixture(reply(data={"workflow_runs": [{"id": 7}], "total_count": 1})))
        self.assertEqual(client.pages("/repos/a/b/actions/runs", collection="workflow_runs"), [{"id": 7}])

    def test_first_page_total_beyond_the_page_bound_fails_page_limit_without_walking(self):
        # #1817: a filtered Actions list reported 2,500 runs; walking ten pages of 100 at about two
        # seconds each only to fail page_limit spent a third of the CI scan on one repository.
        nxt = '<https://api.github.com/repos/a/b/actions/runs?per_page=2&page=2>; rel="next"'
        fixture = HTTPFixture(reply(data={"total_count": 7, "workflow_runs": [1, 2]}, Link=nxt))
        with self.assertRaisesRegex(ClientError, "page_limit"):
            self.client(fixture).pages("/repos/a/b/actions/runs?per_page=2", collection="workflow_runs", max_pages=3)
        self.assertEqual(len(fixture.calls), 1)
        # A total that fits, an absent or non-integer total, or a bare list keeps the ordinary walk.
        for total in (6, None, True, "99"):
            with self.subTest(total=total):
                first = {"workflow_runs": [1, 2]} if total is None else {"total_count": total, "workflow_runs": [1, 2]}
                walk = HTTPFixture(reply(data=first, Link=nxt), reply(data={"workflow_runs": [3]}))
                self.assertEqual(self.client(walk).pages("/repos/a/b/actions/runs?per_page=2", collection="workflow_runs", max_pages=3), [1, 2, 3])
        walk = HTTPFixture(reply(data=[1, 2], Link=nxt), reply(data=[3]))
        self.assertEqual(self.client(walk).pages("/repos/a/b/actions/runs?per_page=2", max_pages=3), [1, 2, 3])
        # #1821 review: a full first page that ends the list while its own total reports rows it did
        # not return lost its next link and fails invalid_page, at the requested or default page size.
        for path, total, rows in (("/repos/a/b/actions/runs?per_page=2", 7, [1, 2]), ("/repos/a/b/actions/runs?per_page=2", 3, [1, 2]),
                                  ("/repos/a/b/actions/runs", 31, list(range(30)))):
            with self.subTest(truncated=(path, total)):
                with self.assertRaisesRegex(ClientError, "invalid_page"):
                    self.client(HTTPFixture(reply(data={"total_count": total, "workflow_runs": rows}))).pages(
                        path, collection="workflow_runs", max_pages=3)
        # A short page is not judged: a busy live-status list can report a total a run off its rows.
        for total, rows in ((3, [1]), (1, [])):
            with self.subTest(short=total):
                self.assertEqual(self.client(HTTPFixture(reply(data={"total_count": total, "workflow_runs": rows}))).pages(
                    "/repos/a/b/actions/runs?per_page=2", collection="workflow_runs", max_pages=3), rows)
        for total in (2, 1, None, True, "9"):
            with self.subTest(complete=total):
                first = {"workflow_runs": [1, 2]} if total is None else {"total_count": total, "workflow_runs": [1, 2]}
                self.assertEqual(self.client(HTTPFixture(reply(data=first))).pages(
                    "/repos/a/b/actions/runs?per_page=2", collection="workflow_runs", max_pages=3), [1, 2])
        # A later page ending the list is not judged against the first page total (the list can move).
        moved = HTTPFixture(reply(data={"total_count": 9, "workflow_runs": [1, 2]}, Link=nxt), reply(data={"total_count": 9, "workflow_runs": [3]}))
        self.assertEqual(self.client(moved).pages("/repos/a/b/actions/runs?per_page=2", collection="workflow_runs", max_pages=5), [1, 2, 3])
        # #1823: an overflowing first page with a bad next link still fails invalid_next_link, the
        # unrecoverable category, and requests nothing more.
        for bad in ('<https://evil.example/repos/a/b/actions/runs?per_page=2&page=2>; rel="next"',
                    '<http://api.github.com/repos/a/b/actions/runs?per_page=2&page=2>; rel="next"',
                    '<https://api.github.com/repos/a/c/actions/runs?per_page=2&page=2>; rel="next"',
                    '<https://api.github.com/repos/a/b/actions/runs?per_page=2&page=0>; rel="next"',
                    '<https://api.github.com/repositories/9/actions/runs?page=2>; rel="next"'):
            with self.subTest(link=bad):
                fixture = HTTPFixture(reply(data={"total_count": 7, "workflow_runs": [1, 2]}, Link=bad))
                with self.assertRaisesRegex(ClientError, "invalid_next_link"):
                    self.client(fixture).pages("/repos/a/b/actions/runs?per_page=2", collection="workflow_runs", max_pages=3)
                self.assertEqual(len(fixture.calls), 1)

    def test_malformed_next_link_does_not_silently_truncate(self):
        for link in ['garbage; rel="next"', '<https://api.github.com/repos/a/b/pulls?page=2>; rel="next"; rel="last"',
                     '<https://api.github.com/repos/a/b/pulls?page=2>; rel="next", garbage']:
            with self.subTest(link=link), self.assertRaisesRegex(ClientError, "invalid_next_link"):
                self.client(HTTPFixture(reply(data=[], Link=link))).pages("/repos/a/b/pulls")

    def test_uncached_304_and_bad_json_are_unavailable(self):
        for response, category in [(reply(304), "uncached_not_modified"),
                                   (Response(200, {}, b"not json"), "invalid_upstream_json")]:
            with self.subTest(category=category), self.assertRaisesRegex(ClientError, category):
                self.client(HTTPFixture(response)).get("/repos/a/b/pulls")

    def test_bounded_cache_evicts_old_page(self):
        fixture = HTTPFixture(reply(data=1, ETag="a"), reply(data=2, ETag="b"), reply(data=3))
        client = self.client(fixture, cache_pages=1)
        client.get("/repos/a/b/pulls/1")
        client.get("/repos/a/b/pulls/2")
        client.get("/repos/a/b/pulls/1")
        self.assertNotIn("If-None-Match", fixture.calls[-1][2])

    def test_budget_denial_unknown_and_primary_reserve(self):
        fixture = HTTPFixture(reply(403, {"message": TOKEN}, **{
            "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4100", "X-RateLimit-Reset": "2000"}),
            reply(data=[], **{"X-RateLimit-Limit": "n/a", "X-RateLimit-Remaining": "-1"}),
            reply(data=[], **{"X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "90", "X-RateLimit-Reset": "2000"}))
        client = self.client(fixture)
        with self.assertRaisesRegex(ClientError, "permission_denied") as error:
            client.get("/repos/a/b/pulls")
        self.assertNotIn(TOKEN, str(error.exception))
        self.assertFalse(client.budget()["core"]["primary_exhausted"])
        self.assertFalse(client.budget()["core"]["secondary_limited"])
        client.get("/repos/a/b/pulls")
        self.assertIsNone(client.budget()["core"]["remaining"])
        client.get("/repos/a/b/pulls")
        with self.assertRaisesRegex(ClientError, "primary_reserve"):
            client.get("/repos/a/b/pulls")
        self.assertEqual(len(fixture.calls), 3)

    def test_primary_and_secondary_limits_are_distinct(self):
        for status, data, headers, category, flag in [
            (403, {}, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"}, "primary_exhausted", "primary_exhausted"),
            (403, {"message": "secondary rate limit"}, {"X-RateLimit-Remaining": "4900"}, "secondary_limit", "secondary_limited"),
            (429, {}, {"Retry-After": "120"}, "secondary_limit", "secondary_limited"),
        ]:
            with self.subTest(category=category):
                client = self.client(HTTPFixture(reply(status, data, **headers)))
                with self.assertRaisesRegex(ClientError, category):
                    client.get("/repos/a/b/pulls")
                self.assertTrue(client.budget()["core"][flag])
        clock = Clock()
        fixture = HTTPFixture(reply(429, {}, **{"Retry-After": "120"}), reply(data=[]))
        client = self.client(fixture, clock)
        with self.assertRaises(ClientError):
            client.get("/repos/a/b/pulls")
        with self.assertRaisesRegex(ClientError, "upstream_backoff"):
            client.query("{ viewer { login } }")
        self.assertEqual(len(fixture.calls), 1)
        clock.now += 121
        self.assertEqual(client.get("/repos/a/b/pulls"), [])

    def test_graphql_http200_secondary_limit_keeps_headers_and_gates_all_reads(self):
        clock = Clock()
        fixture = HTTPFixture(reply(data={"errors": [{"message": "You have exceeded a secondary rate limit. " + TOKEN}]}, **{
            "Retry-After": "120", "X-RateLimit-Resource": "graphql", "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4900", "X-RateLimit-Reset": "2000"}), reply(data=[]))
        client = self.client(fixture, clock)
        with self.assertRaisesRegex(ClientError, "secondary_limit") as error:
            client.query("{ viewer { login } }")
        self.assertEqual(error.exception.retry_after, 120)
        self.assertNotIn(TOKEN, str(error.exception))
        budget = client.budget()["graphql"]
        self.assertTrue(budget["secondary_limited"])
        self.assertFalse(budget["primary_exhausted"])
        self.assertEqual((budget["remaining"], budget["limit"], budget["status"]), (4900, 5000, 200))
        with self.assertRaisesRegex(ClientError, "upstream_backoff"):
            client.get("/repos/a/b/pulls")
        self.assertEqual(len(fixture.calls), 1)
        clock.now += 121
        self.assertEqual(client.get("/repos/a/b/pulls"), [])

    def test_primary_429_only_blocks_its_observed_pool_until_reset(self):
        for path, resource, limit in [("/search/issues?q=x", "search", "30"),
                                      ("/search/code?q=x", "code_search", "10")]:
            with self.subTest(resource=resource):
                clock = Clock()
                fixture = HTTPFixture(reply(429, {"message": TOKEN}, **{
                    "X-RateLimit-Resource": resource, "X-RateLimit-Limit": limit,
                    "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"}),
                    reply(data=[]), reply(data={"data": {"viewer": {"login": "fixture"}}}), reply(data=[]))
                client = self.client(fixture, clock)
                with self.assertRaisesRegex(ClientError, "primary_exhausted") as error:
                    client.get(path)
                self.assertEqual(error.exception.retry_after, 1000)
                self.assertNotIn(TOKEN, str(error.exception))
                evidence = client.budget()[resource]
                self.assertTrue(evidence["primary_exhausted"])
                self.assertFalse(evidence["secondary_limited"])
                self.assertEqual((evidence["status"], evidence["remaining"], evidence["reset"]), (429, 0, 2000))
                with self.assertRaisesRegex(ClientError, "primary_exhausted"):
                    client.get(path)
                self.assertEqual(len(fixture.calls), 1)
                self.assertEqual(client.get("/repos/a/b/pulls"), [])
                self.assertEqual(client.query("{ viewer { login } }"), {"viewer": {"login": "fixture"}})
                self.assertEqual(len(fixture.calls), 3)
                clock.now = 2001
                self.assertEqual(client.get(path), [])
                self.assertEqual(len(fixture.calls), 4)

    def test_explicit_secondary_evidence_still_gates_all_pools_when_primary_zero(self):
        cases = [(429, {"message": "secondary rate limit " + TOKEN}, {}, 60),
                 (429, {}, {"Retry-After": "120"}, 120),
                 (403, {"message": "abuse detection " + TOKEN}, {}, 60),
                 (403, {}, {"Retry-After": "120"}, 120),
                 (200, {"errors": [{"message": "secondary rate limit " + TOKEN}]}, {}, 60)]
        for status, body, extra, delay in cases:
            with self.subTest(status=status, extra=extra):
                resource = "graphql" if status == 200 else "search"
                fixture = HTTPFixture(reply(status, body, **{
                    "X-RateLimit-Resource": resource, "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "2000", **extra}))
                client = self.client(fixture)
                with self.assertRaisesRegex(ClientError, "secondary_limit") as error:
                    if status == 200:
                        client.query("{ viewer { login } }")
                    else:
                        client.get("/search/issues?q=x")
                self.assertEqual(error.exception.retry_after, delay)
                self.assertNotIn(TOKEN, str(error.exception))
                self.assertTrue(client.budget()[resource]["primary_exhausted"])
                self.assertTrue(client.budget()[resource]["secondary_limited"])
                for read in [lambda: client.get("/repos/a/b/pulls"),
                             lambda: client.query("{ viewer { login } }")]:
                    with self.assertRaisesRegex(ClientError, "upstream_backoff"):
                        read()
                self.assertEqual(len(fixture.calls), 1)

    def test_graphql_success_text_and_generic_errors_are_not_secondary_limits(self):
        for payload, expected in [
            ({"errors": [{"message": "generic error " + TOKEN}]}, "incomplete_graphql"),
            ({"data": {"message": "secondary rate limit"}}, None),
        ]:
            fixture = HTTPFixture(reply(data=payload, **{"Retry-After": "120", "X-RateLimit-Resource": "graphql"}), reply(data=[]))
            client = self.client(fixture)
            if expected:
                with self.assertRaisesRegex(ClientError, expected): client.query("{ viewer { login } }")
            else:
                self.assertEqual(client.query("{ viewer { login } }"), payload["data"])
            self.assertFalse(client.budget()["graphql"]["secondary_limited"])
            self.assertEqual(client.get("/repos/a/b/pulls"), [])
            self.assertEqual(len(fixture.calls), 2)
        client = self.client(HTTPFixture(reply(data={"errors": [{"message": "secondary rate limit"}]})))
        client.get("/repos/a/b/pulls")
        self.assertFalse(client.budget()["core"]["secondary_limited"])

    def test_query_batches_aliases_and_rejects_every_write(self):
        fixture = HTTPFixture(reply(data={"data": {"first": 1, "second": 2}}, **{
            "X-RateLimit-Resource": "graphql", "X-RateLimit-Remaining": "4900"}))
        client = self.client(fixture)
        document = 'query Batch { first: viewer { login } second: repository(owner:"mutation", name:"b") { id } }'
        self.assertEqual(client.query(document),
                         {"first": 1, "second": 2})
        self.assertEqual(fixture.calls[0][0:2], ("POST", ORIGIN + "/graphql"))
        self.assertEqual(json.loads(fixture.calls[0][3]), {"query": document, "variables": {}})
        for query in ["mutation { addComment(input:{body:\"x\"}) { clientMutationId } }",
                      "subscription { viewer { login } }",
                      "{ viewer { login } } mutation { deleteIssue(input:{id:\"x\"}) { clientMutationId } }",
                      "query { viewer { login } } # query\n mutation { x }",
                      'query { viewer { login } } mutation { x(body:"query") }']:
            with self.subTest(query=query), self.assertRaises(ClientError):
                client.query(query)
        self.assertEqual(len(fixture.calls), 1)

    def test_query_errors_and_cursor_incompleteness_fail_closed(self):
        client = self.client(HTTPFixture(reply(data={"data": {"viewer": None}, "errors": [{"message": TOKEN}]})))
        with self.assertRaisesRegex(ClientError, "incomplete_graphql"):
            client.query("{ viewer { login } }")
        self.assertIsNone(client.next_cursor({"pageInfo": {"hasNextPage": False}}))
        self.assertEqual(client.next_cursor({"pageInfo": {"hasNextPage": True, "endCursor": "next"}}), "next")
        for connection in [{}, {"pageInfo": {}}, {"pageInfo": {"hasNextPage": True, "endCursor": None}}]:
            with self.assertRaises(ClientError):
                client.next_cursor(connection)

    def test_query_input_object_defaults_are_one_read_and_trailing_operations_fail(self):
        documents = [
            'query Q($filter: Filter = {states: OPEN}) { repository(owner:"a", name:"b") { id } }',
            'query Q($filter: Filter = {nested: [{states: [OPEN], note: "mutation { x }"}]}) { viewer { login } }',
            'query Q($mutation: Filter = {subscription: OPEN}) { viewer { login } }',
        ]
        for document in documents:
            fixture = HTTPFixture(reply(data={"data": {"fixture": 1}}))
            client = self.client(fixture)
            self.assertEqual(client.query(document), {"fixture": 1})
            self.assertEqual(len(fixture.calls), 1)
            self.assertEqual(json.loads(fixture.calls[0][3])["query"], document)
            for suffix in [" mutation { deleteIssue(input:{id:\"x\"}) { clientMutationId } }",
                           " subscription { viewer { login } }", " query Other { viewer { login } }",
                           " fragment F on User { login }"]:
                with self.assertRaises(ClientError):
                    client.query(document + suffix)
            self.assertEqual(len(fixture.calls), 1)
        for document in ['query Q($x: Input = {nested: [OPEN}) { viewer { login } }',
                         'query Q($x: Input = {states: OPEN}) { viewer { login }',
                         'query Q($x: String = "unterminated) { viewer { login } }']:
            fixture = HTTPFixture()
            with self.assertRaises(ClientError):
                self.client(fixture).query(document)
            self.assertEqual(fixture.calls, [])

    def test_query_variables_default_only_none_and_reject_invalid_objects(self):
        document = 'query Q($name: String = "default") { viewer { login } }'
        for variables in [[], False, "", 0, (), [1], "nonempty", {1: "collision", "1": "other"}, {None: 1}]:
            fixture = HTTPFixture()
            with self.subTest(variables=variables), self.assertRaisesRegex(ClientError, "invalid_query_variables"):
                self.client(fixture).query(document, variables)
            self.assertEqual(fixture.calls, [])
        for variables, expected in [(None, {}), ({}, {}), ({"name": "fixture"}, {"name": "fixture"})]:
            fixture = HTTPFixture(reply(data={"data": {"viewer": {"login": "fixture"}}}))
            self.client(fixture).query(document, variables)
            self.assertEqual(json.loads(fixture.calls[0][3])["variables"], expected)
            self.assertEqual(len(fixture.calls), 1)

    def test_query_variables_recursively_refuse_loss_before_transport(self):
        cycle = []; cycle.append(cycle)
        mapping_cycle = {}; mapping_cycle["self"] = mapping_cycle
        deep = None
        for _ in range(sys.getrecursionlimit() + 1):
            deep = [deep]
        invalid = [{1: "first", "1": "second"}, (1, 2), {"nested": (1, 2)},
                   [{False: 1}], float("nan"), float("inf"), cycle, mapping_cycle, deep, object()]
        for value in invalid:
            fixture = HTTPFixture()
            with self.subTest(kind=type(value).__name__), self.assertRaisesRegex(ClientError, "invalid_query_variables"):
                self.client(fixture).query("query { viewer { login } }", {"filter": value})
            self.assertEqual(fixture.calls, [])
        def values():
            return [None, True, 3, 0.25, "text", {"states": []}]
        variables = {"filter": {"nested": values(), "also": values()}}
        fixture = HTTPFixture(reply(data={"data": {"viewer": {"login": "fixture"}}}))
        self.client(fixture).query("query { viewer { login } }", variables)
        self.assertEqual(json.loads(fixture.calls[0][3])["variables"], variables)
        self.assertEqual(len(fixture.calls), 1)

    def test_query_refuses_shared_container_expansion_before_request(self):
        shared_list, shared_dict = [], {"value": 1}
        graph = []
        for _ in range(8):
            graph = [graph, graph]
        for value in [[shared_list, shared_list], {"first": shared_dict, "second": shared_dict}, graph]:
            fixture = HTTPFixture()
            with self.assertRaisesRegex(ClientError, "invalid_query_variables"):
                self.client(fixture).query("query { viewer { login } }", {"value": value})
            self.assertEqual(fixture.calls, [])

    def test_browser_json_preserves_safe_numbers_and_exact_decimal_strings(self):
        sample = {"counts": [0, -(2 ** 53 - 1), 2 ** 53 - 1],
                  "opaque_ids": ["9007199254740993", "-9007199254740993"]}
        encoded = json.dumps(copy_json_tree(sample), allow_nan=False)
        result = subprocess.run(
            ["node", "-e", "const fs = require('node:fs'); const value = JSON.parse(fs.readFileSync(0, 'utf8')); "
             "if (!value.counts.every(Number.isSafeInteger)) process.exit(1); "
             "process.stdout.write(JSON.stringify(value));"],
            input=encoded, text=True, capture_output=True, timeout=5, check=True,
        )
        self.assertEqual(json.loads(result.stdout), sample)

    def test_client_error_only_retains_registered_stable_categories(self):
        private = "upstream body /private/fixture unrelated-credential-do-not-publish"
        class UntrustedText(str):
            def __str__(self):
                raise AssertionError("untrusted category must never be coerced")
        for category in [private, "provider_unregistered", "x" * 10000, "", None, {}, object(), UntrustedText("permission_denied")]:
            with self.subTest(kind=type(category).__name__):
                error = ClientError(category, 120)
                self.assertEqual(error.category, "source_failed")
                self.assertEqual(str(error), "source_failed")
                self.assertEqual(error.args, ("source_failed",))
                self.assertEqual(error.retry_after, 120)
        for category in ["permission_denied", "secondary_limit"]:
            self.assertEqual(ClientError(category).category, category)

    def test_retry_delay_refuses_invalid_values_without_coercion_or_duration_cap(self):
        for value in [float("inf"), float("-inf"), float("nan"), -1, True, "120", {}, 10 ** 400]:
            with self.subTest(kind=type(value).__name__):
                self.assertEqual(ClientError("secondary_limit", value).retry_after, 0)
        for value in [0, 120, 1.5, 1000000]:
            self.assertEqual(ClientError("secondary_limit", value).retry_after, value)

    def test_deadline_and_fixed_origin_no_ambient_fallback(self):
        fixture = HTTPFixture()
        client = self.client(fixture)
        for path in ["https://evil.example/repos/a/b", "//evil.example/repos/a/b", "/rate_limit", "/repos/a/../b", "/repos/a/b#fragment"]:
            with self.subTest(path=path), self.assertRaises(ClientError):
                client.get(path)
        with self.assertRaisesRegex(ClientError, "deadline_exceeded"):
            client.pages("/repos/a/b/pulls", deadline=999)
        with self.assertRaisesRegex(ClientError, "cached_reviewer_credential_required"):
            GitHubClient.from_environment({"GH_TOKEN": TOKEN, "OP_PREFLIGHT_AUTHOR_PAT": TOKEN})
        self.assertFalse(fixture.calls)

    def test_budget_credential_identity_is_configured_not_live_observed(self):
        fixture = HTTPFixture(reply(data=[]))
        client = GitHubClient.from_environment({"OP_PREFLIGHT_REVIEWER_PAT": TOKEN,
            "OP_PREFLIGHT_AGENT": "codex"}, transport=fixture)
        client.get("/repos/a/b/pulls")
        evidence = client.budget()["core"]
        self.assertEqual(evidence["credential_source"], "OP_PREFLIGHT_REVIEWER_PAT")
        self.assertEqual(evidence["configured_identity"], "nathanpayne-codex")
        self.assertEqual(evidence["identity_evidence"], "preflight_configured")
        self.assertEqual(evidence["resource"], "core")
        self.assertEqual(len(fixture.calls), 1)

    def test_snapshot_budget_does_not_wait_for_upstream(self):
        entered, release = threading.Event(), threading.Event()
        def transport(*args):
            entered.set()
            release.wait(1)
            return reply(data=[])
        client = self.client(transport)
        thread = threading.Thread(target=client.get, args=("/repos/a/b/pulls",), daemon=True)
        thread.start()
        self.assertTrue(entered.wait(1))
        start = time.monotonic()
        self.assertEqual(client.budget(), {})
        self.assertLess(time.monotonic() - start, 0.1)
        release.set()
        thread.join(1)

    def test_waiting_transport_lock_honors_caller_deadline(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def transport(*args):
            calls.append(args); entered.set(); release.wait(1)
            return reply(data=[])
        client = GitHubClient(TOKEN, transport=transport)
        thread = threading.Thread(target=client.get, args=("/repos/a/b/pulls",), daemon=True)
        thread.start(); self.assertTrue(entered.wait(1))
        started = time.monotonic()
        with self.assertRaisesRegex(ClientError, "deadline_exceeded"):
            client.get("/repos/a/b/issues", deadline=started + 0.025)
        self.assertLess(time.monotonic() - started, 0.1)
        self.assertEqual(len(calls), 1)
        release.set(); thread.join(1)

    def test_late_reply_is_discarded_but_headers_remain_observed(self):
        def transport(*args):
            time.sleep(0.025)
            return reply(data=["late"], **{"X-RateLimit-Remaining": "4900"})
        client = GitHubClient(TOKEN, transport=transport)
        with self.assertRaisesRegex(ClientError, "deadline_exceeded"):
            client.get("/repos/a/b/pulls", deadline=time.monotonic() + 0.005)
        self.assertEqual(client.budget()["core"]["remaining"], 4900)
        self.assertEqual(len(client._cache), 0)

    def test_search_checks_its_own_resource_reserve(self):
        fixture = HTTPFixture(reply(data=[], **{"X-RateLimit-Resource": "search",
            "X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"}))
        client = self.client(fixture)
        client.get("/search/issues?q=repo:a/b")
        with self.assertRaisesRegex(ClientError, "primary_exhausted"):
            client.get("/search/issues?q=repo:a/b")
        self.assertEqual(len(fixture.calls), 1)

    def test_small_search_pools_remain_usable(self):
        for path, resource, limit, remaining in [
            ("/search/issues?q=repo:a/b", "search", 30, 29),
            ("/search/code?q=repo:a/b", "code_search", 10, 9),
        ]:
            with self.subTest(resource=resource):
                headers = {"X-RateLimit-Resource": resource, "X-RateLimit-Limit": str(limit),
                           "X-RateLimit-Remaining": str(remaining), "X-RateLimit-Reset": "2000"}
                fixture = HTTPFixture(reply(data=[], **headers), reply(data=[], **headers))
                client = self.client(fixture)
                client.get(path); client.get(path)
                self.assertEqual(len(fixture.calls), 2)
                self.assertFalse(client.budget()[resource]["primary_exhausted"])

    def test_code_search_exhaustion_is_not_search_or_core_exhaustion(self):
        fixture = HTTPFixture(reply(data=[], **{"X-RateLimit-Resource": "code_search",
            "X-RateLimit-Limit": "10", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"}),
            reply(data=[]), reply(data=[]))
        client = self.client(fixture)
        client.get("/search/code?q=repo:a/b")
        with self.assertRaisesRegex(ClientError, "primary_exhausted"):
            client.get("/search/code?q=repo:a/b&page=2")
        client.get("/search/issues?q=repo:a/b")
        client.get("/repos/a/b/pulls")
        self.assertEqual(len(fixture.calls), 3)

    def test_response_resource_is_learned_for_get_and_pagination(self):
        for paginate in [False, True]:
            with self.subTest(paginate=paginate):
                link = '<https://api.github.com/repos/a/b/pulls?page=2>; rel="next"' if paginate else ""
                fixture = HTTPFixture(reply(data=[1], Link=link, **{
                    "X-RateLimit-Resource": "search", "X-RateLimit-Limit": "30",
                    "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"}))
                client = self.client(fixture)
                with self.assertRaisesRegex(ClientError, "primary_exhausted"):
                    if paginate:
                        client.pages("/repos/a/b/pulls")
                    else:
                        client.get("/repos/a/b/pulls")
                        client.get("/repos/a/b/pulls?page=2")
                self.assertEqual(len(fixture.calls), 1)

    def test_reserve_uses_observed_limit_and_never_invents_one(self):
        for limit, remaining, blocked in [("5000", "100", True), ("5000", "101", False),
                                           (None, "1", False), ("n/a", "1", False), ("0", "1", False)]:
            with self.subTest(limit=limit, remaining=remaining):
                headers = {"X-RateLimit-Remaining": remaining, "X-RateLimit-Reset": "2000"}
                if limit is not None:
                    headers["X-RateLimit-Limit"] = limit
                fixture = HTTPFixture(reply(data=[], **headers), reply(data=[]))
                client = self.client(fixture)
                client.get("/repos/a/b/pulls")
                evidence = client.budget()["core"]
                self.assertFalse(evidence["primary_exhausted"])
                self.assertEqual(evidence["limit"], 5000 if limit == "5000" else 0 if limit == "0" else None)
                if blocked:
                    with self.assertRaisesRegex(ClientError, "primary_reserve"):
                        client.get("/repos/a/b/pulls")
                else:
                    client.get("/repos/a/b/pulls")
                self.assertEqual(len(fixture.calls), 1 if blocked else 2)

    def test_learned_resource_map_is_bounded(self):
        fixture = HTTPFixture(reply(data=[], **{"X-RateLimit-Resource": "search"}), reply(data=[]))
        client = self.client(fixture, cache_pages=1)
        client.get("/repos/a/b/pulls"); client.get("/repos/a/b/issues")
        self.assertEqual(len(client._endpoint_resources), 1)
        self.assertEqual(client._resource("/repos/a/b/pulls"), "core")

    def test_oversized_denial_still_accounts_throttle_headers(self):
        fixture = HTTPFixture(Response(403, {"Retry-After": "120", "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "2000"}, b"x" * (MAX_BODY + 1)))
        client = self.client(fixture)
        with self.assertRaisesRegex(ClientError, "secondary_limit"):
            client.get("/repos/a/b/pulls")
        self.assertTrue(client.budget()["core"]["secondary_limited"])
        with self.assertRaisesRegex(ClientError, "upstream_backoff"):
            client.get("/repos/a/b/pulls")
        self.assertEqual(len(fixture.calls), 1)

    def test_real_transport_uses_fixed_https_and_does_not_redirect(self):
        class FakeReply:
            status = 302
            def getheaders(self): return [("Location", "https://evil.example/")]
            def read1(self, amount): return b""
        connection = SimpleNamespace(connect=lambda: None, close=lambda: None,
            sock=SimpleNamespace(settimeout=lambda value: None, shutdown=lambda how: None),
            request=lambda *args, **kwargs: None, getresponse=lambda: FakeReply())
        with patch("http.client.HTTPSConnection", return_value=connection) as factory:
            result = http_transport("GET", ORIGIN + "/repos/a/b/pulls", {}, None, 1)
        self.assertEqual(result.status, 302)
        factory.assert_called_once_with("api.github.com", timeout=1)

    def test_real_transport_slow_drip_body_is_bounded(self):
        listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen()
        self.addCleanup(listener.close)
        port = listener.getsockname()[1]
        def drip():
            connection, _ = listener.accept()
            with connection:
                connection.recv(4096)
                connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nX-RateLimit-Remaining: 4900\r\n\r\n")
                try:
                    for _ in range(100):
                        connection.sendall(b"x"); time.sleep(0.005)
                except OSError:
                    pass
        thread = threading.Thread(target=drip, daemon=True); thread.start()
        plain_http = http.client.HTTPConnection
        with patch("http.client.HTTPSConnection", side_effect=lambda host, timeout: plain_http("127.0.0.1", port, timeout=timeout)):
            started = time.monotonic()
            with self.assertRaisesRegex(ClientError, "deadline_exceeded") as error:
                http_transport("GET", ORIGIN + "/repos/a/b/pulls", {}, None, 0.025)
            self.assertLess(time.monotonic() - started, 0.15)
            self.assertEqual(error.exception.response.headers["X-RateLimit-Remaining"], "4900")
        thread.join(0.2)


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.scheduler = Scheduler(workers=1, clock=self.clock, monotonic=self.clock)
        self.addCleanup(self.scheduler.close)

    def settle(self, name):
        wait_until(lambda: not self.scheduler.snapshot()[name]["in_flight"])

    def test_worker_bound_is_native_integer_one_or_two(self):
        for workers in [0, 3, 8, True, 1.0, "2", None]:
            with self.subTest(workers=workers), self.assertRaisesRegex(ValueError, "invalid_worker_bound"):
                Scheduler(workers=workers)
        for workers in [1, 2]:
            scheduler = Scheduler(workers=workers)
            scheduler.close()

    def test_mutated_retry_delay_retains_last_good_and_json_publication(self):
        for index, delay in enumerate([float("inf"), float("nan"), "120", {}, True, 10 ** 400]):
            error = ClientError("secondary_limit", 120)
            error.retry_after = delay
            results = [Sample({"last_good": [1]}), error]
            def fetch(deadline, results=results):
                result = results.pop(0)
                if isinstance(result, Exception):
                    raise result
                return result
            name = f"retry_{index}"
            self.scheduler.register(name, fetch)
            self.scheduler.tick(); self.settle(name)
            first = self.scheduler.snapshot()[name]
            self.clock.now += 1
            self.scheduler.refresh(name); self.scheduler.tick(); self.settle(name)
            current = self.scheduler.snapshot()[name]
            self.assertEqual(current["data"], first["data"])
            self.assertEqual(current["observed_at"], first["observed_at"])
            self.assertEqual(current["error"], "secondary_limit")
            self.assertTrue(current["stale"])
            self.assertTrue(math.isfinite(current["retry_at"]))
            self.assertEqual(current["retry_at"], self.clock.now + 15)
            json.dumps(self.scheduler.snapshot(), allow_nan=False)

    def test_retry_timestamp_overflow_falls_back_to_ordinary_backoff(self):
        scheduler = Scheduler(workers=1, clock=lambda: 1e308, monotonic=self.clock)
        self.addCleanup(scheduler.close)
        calls = []
        def fetch(deadline):
            calls.append(deadline)
            raise ClientError("secondary_limit", 1e308)
        scheduler.register("overflow", fetch)
        scheduler.tick()
        wait_until(lambda: not scheduler.snapshot()["overflow"]["in_flight"])
        self.assertTrue(math.isfinite(scheduler.snapshot()["overflow"]["retry_at"]))
        json.dumps(scheduler.snapshot(), allow_nan=False)
        self.clock.now += 1
        scheduler.tick()
        self.assertEqual(len(calls), 1)
        self.clock.now += 14
        scheduler.tick()
        wait_until(lambda: not scheduler.snapshot()["overflow"]["in_flight"])
        self.assertEqual(len(calls), 2)

    def test_strict_json_tree_rejects_loss_without_replacing_last_good(self):
        cycle = []; cycle.append(cycle)
        invalid = [(1, 2), {"nested": (1, 2)}, {1: "first", "1": "second"}, {"nested": {False: 1}},
                   float("nan"), float("inf"), cycle, {"object": object()}]
        for index, value in enumerate(invalid):
            name = f"source_{index}"
            results = [Sample({"last_good": [1]}), Sample(value)]
            self.scheduler.register(name, lambda deadline, results=results: results.pop(0))
            self.scheduler.tick(); self.settle(name)
            first = self.scheduler.snapshot()[name]
            self.clock.now += 1
            self.scheduler.refresh(name); self.scheduler.tick(); self.settle(name)
            current = self.scheduler.snapshot()[name]
            self.assertEqual(current["data"], first["data"])
            self.assertEqual(current["observed_at"], first["observed_at"])
            self.assertTrue(current["stale"])
            self.assertEqual(current["error"], "source_failed")

    def test_native_json_tree_is_copied_without_coercion_or_aliasing(self):
        def values():
            return [None, True, 3, 0.25, "text", {"nested": []}]
        data = {"first": values(), "second": values()}
        self.scheduler.register("native", lambda deadline: Sample(data))
        self.scheduler.tick(); self.settle("native")
        current = self.scheduler.snapshot()["native"]
        self.assertEqual(current["data"], data)
        self.assertFalse(current["stale"])
        self.assertIsNone(current["error"])
        data["first"].append("provider mutation")
        self.assertNotIn("provider mutation", self.scheduler.snapshot()["native"]["data"]["first"])

    def test_shared_container_sample_is_failed_without_expansion_or_lost_age(self):
        graph = []
        for _ in range(8):
            graph = [graph, graph]
        results = [Sample({"last_good": [1]}), Sample({"graph": graph})]
        self.scheduler.register("shared", lambda deadline: results.pop(0))
        self.scheduler.tick(); self.settle("shared")
        first = self.scheduler.snapshot()["shared"]
        self.clock.now += 1
        self.scheduler.refresh("shared"); self.scheduler.tick(); self.settle("shared")
        current = self.scheduler.snapshot()["shared"]
        self.assertEqual(current["error"], "source_failed")
        self.assertEqual(current["data"], first["data"])
        self.assertEqual(current["observed_at"], first["observed_at"])
        self.assertTrue(current["stale"])

    def test_hot_idle_and_stale_last_good(self):
        results = [Sample({"value": 1}, True), ClientError("permission_denied"), Sample({"value": 2})]
        def fetch(deadline):
            result = results.pop(0)
            if isinstance(result, Exception): raise result
            return result
        self.scheduler.register("prs", fetch)
        self.assertEqual(self.scheduler.snapshot()["prs"]["error"], "unavailable")
        self.scheduler.tick(); self.settle("prs")
        first = self.scheduler.snapshot()["prs"]
        self.assertEqual(first["retry_at"], 1015)
        first["data"]["value"] = 99
        self.clock.now = 1015
        self.scheduler.tick(); self.settle("prs")
        failed = self.scheduler.snapshot()["prs"]
        self.assertEqual(failed["data"], {"value": 1})
        self.assertEqual(failed["observed_at"], 1000)
        self.assertTrue(failed["stale"])
        self.assertEqual(failed["retry_at"], 1030)
        self.clock.now = 1030
        self.scheduler.tick(); self.settle("prs")
        self.assertEqual(self.scheduler.snapshot()["prs"]["retry_at"], 1150)

    def test_refresh_cannot_bypass_single_flight_backoff_or_worker_bound(self):
        release, entered = threading.Event(), threading.Event()
        calls = []
        def fetch(deadline):
            calls.append(deadline); entered.set(); release.wait(1)
            raise ClientError("secondary_limit", 120)
        self.scheduler.register("first", fetch)
        self.scheduler.register("second", lambda deadline: Sample(2))
        self.scheduler.tick()
        self.assertTrue(entered.wait(1))
        for _ in range(5):
            self.scheduler.refresh("first"); self.scheduler.tick()
        self.assertEqual(len(calls), 1)
        self.assertFalse(self.scheduler.snapshot()["second"]["in_flight"])
        release.set(); self.settle("first")
        self.scheduler.refresh("first"); self.scheduler.tick(); self.settle("second")
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.scheduler.snapshot()["first"]["retry_at"], 1120)

    def test_expired_callback_is_stale_discards_late_result_and_retains_fence(self):
        entered, release = threading.Event(), threading.Event()
        def fetch(deadline):
            entered.set(); release.wait(1); return Sample("late")
        self.scheduler.register("hung", fetch, timeout=10)
        self.scheduler.tick()
        self.assertTrue(entered.wait(1))
        self.clock.now += 11
        self.scheduler.tick()
        self.assertEqual(self.scheduler.snapshot()["hung"]["error"], "deadline_exceeded")
        self.assertTrue(self.scheduler.snapshot()["hung"]["in_flight"])
        release.set(); self.settle("hung")
        self.assertIsNone(self.scheduler.snapshot()["hung"]["data"])

    def test_errors_are_sanitized_and_invalid_json_is_unavailable(self):
        for name, fetch in [("secret", lambda deadline: (_ for _ in ()).throw(ValueError(TOKEN))),
                            ("invalid", lambda deadline: Sample(float("nan")))]:
            self.scheduler.register(name, fetch)
            self.scheduler.tick(); self.settle(name)
            self.assertEqual(self.scheduler.snapshot()[name]["error"], "source_failed")
        self.assertNotIn(TOKEN, json.dumps(self.scheduler.snapshot()))

    def test_mutated_client_error_category_is_sanitized_at_scheduler_boundary(self):
        error = ClientError("permission_denied", 120)
        error.category = "private upstream body /private/fixture unrelated-credential-do-not-publish"
        results = [Sample({"last_good": 1}), error]
        def fetch(deadline):
            value = results.pop(0)
            if isinstance(value, Exception): raise value
            return value
        self.scheduler.register("category", fetch)
        self.scheduler.tick(); self.settle("category")
        first = self.scheduler.snapshot()["category"]
        self.clock.now += 1
        self.scheduler.refresh("category"); self.scheduler.tick(); self.settle("category")
        current = self.scheduler.snapshot()["category"]
        self.assertEqual(current["error"], "source_failed")
        self.assertEqual(current["data"], first["data"])
        self.assertEqual(current["observed_at"], first["observed_at"])
        self.assertTrue(current["stale"])
        self.assertEqual(current["retry_at"], self.clock.now + 120)
        self.assertNotIn(error.category, json.dumps(current))


class AdmissionSlots(threading.BoundedSemaphore):
    """Expose a saturated accept attempt without scheduling sleeps in the client."""
    def __init__(self):
        super().__init__(8)
        self.saturated = threading.Event()
        self.admission_finished = threading.Event()

    def acquire(self, *args, **kwargs):
        with self._cond:
            saturated = self._value == 0
        if saturated:
            self.saturated.set()
        result = super().acquire(*args, **kwargs)
        if saturated:
            self.admission_finished.set()
        return result


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "assets").mkdir()
        (self.root / "index.html").write_text("<!doctype html><p>HTTP fixture only</p>")
        (self.root / "assets" / "fixture.js").write_text('document.body.textContent = "fixture";')
        (self.root / "assets" / "secret.py").write_text(TOKEN)
        self.logs = []
        self.github = GitHubClient(TOKEN, transport=HTTPFixture())
        self.app = Application((Repository("mergepath", HUB, True), Repository("consumer", "a/b")),
                               self.github, static_root=self.root, heartbeat=0.025, logger=self.logs.append)
        self.server = CockpitServer(self.app)
        self.port = self.server.server_address[1]
        self.host = f"127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.thread.start()
        self.connections = []
        self.addCleanup(self.close)
        self.cookie = None

    def close(self):
        for connection in self.connections:
            connection.close()
        self.app.close(); self.server.shutdown(); self.server.server_close(); self.thread.join(1)

    def request(self, method="GET", path="/api/snapshot", *, headers=None, authenticated=True, stream=False, scoped=True, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=1)
        self.connections.append(connection)
        if scoped and path not in {"/bootstrap", "/bootstrap.js", "/api/bootstrap"}:
            path = self.app.scope_path + path.lstrip("/")
        connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        pairs = [("Host", self.host)] if headers is None else list(headers)
        if authenticated and self.cookie:
            pairs.append(("Cookie", self.cookie))
        for key, value in pairs: connection.putheader(key, value)
        connection.endheaders(body)
        response = connection.getresponse()
        if stream:
            return response
        data, response_headers, status = response.read(), dict(response.getheaders()), response.status
        connection.close()
        return status, response_headers, data

    def bootstrap(self):
        status, headers, body = self.request("POST", "/api/bootstrap", authenticated=False, headers=[
            ("Host", self.host), ("Origin", "http://" + self.host),
            ("X-Cockpit-Bootstrap", self.app._nonce), ("X-Cockpit-CSRF", self.app._nonce)])
        self.assertEqual(status, 204)
        self.cookie = headers["Set-Cookie"].split(";")[0]
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        # Lax, not Strict: Safari withholds a Strict cookie on the history navigation back to the
        # page after the tab visited another site, and the Cockpit answered 401 (#1844).
        self.assertIn("SameSite=Lax", headers["Set-Cookie"]); self.assertNotIn("Strict", headers["Set-Cookie"])
        self.assertIn("Path=" + self.app.scope_path, headers["Set-Cookie"])
        self.assertNotEqual(self.cookie.split("=", 1)[1], self.app._nonce)

    def test_loopback_exact_host_duplicate_and_foreign_origin_refusals(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.bootstrap()
        for headers in [[], [("Host", "evil.example")], [("Host", self.host), ("Host", self.host)],
                        [("Host", self.host), ("Origin", "https://evil.example")],
                        [("Host", self.host), ("Sec-Fetch-Site", "same-site")]]:
            with self.subTest(headers=headers):
                self.assertEqual(self.request(headers=headers)[0], 403)
        self.assertEqual(self.request(headers=[("Host", f"localhost:{self.port}")])[0], 200)

    def test_namespace_is_required_with_cookie_and_never_disclosed_unscoped(self):
        self.bootstrap()
        self.assertEqual(len(self.app._scope), 43)
        for route in ["/api/session", "/api/snapshot", "/api/panels/prs", "/events", "/assets/fixture.js",
                      "/?reopen=1", "/?", "/bootstrap?", "/bootstrap.js?"]:
            status, headers, body = self.request(path=route, scoped=False)
            self.assertEqual(status, 404)
            self.assertNotIn("Location", headers)
            for secret in [self.app._scope, self.app._session, self.app._nonce, TOKEN]:
                self.assertNotIn(secret.encode(), body)
            self.assertEqual(self.request(path=route, authenticated=False)[0], 401)
        for prefix in ["/s/" + "x" * 43 + "/", self.app.scope_path.rstrip("/") + "extra/"]:
            self.assertEqual(self.request(path=prefix + "api/snapshot", scoped=False)[0], 404)
        self.assertEqual(self.request()[0], 200)

    def test_printed_base_url_serves_only_the_secret_free_reopen_document(self):
        # The terminal prints the base URL; it reopens the stored session in the browser
        # that launched it and must never disclose the namespace or a credential (#1848).
        self.bootstrap()
        transport = (ROOT / "mergepath/cockpit/bootstrap.html").read_bytes()
        for authenticated in (True, False):
            with self.subTest(authenticated=authenticated):
                status, headers, body = self.request(path="/", scoped=False, authenticated=authenticated)
                self.assertEqual(status, 200)
                self.assertEqual(body, transport)
                self.assertNotIn("Location", headers)
                self.assertNotIn("Set-Cookie", headers)
                self.assertEqual(headers["Content-Security-Policy"], CSP)
                self.assertEqual(headers["Cache-Control"], "no-store")
                for secret in [self.app._scope, self.app._session, self.app._nonce, self.app._csrf, TOKEN]:
                    self.assertNotIn(secret.encode(), body)
        for method in ["POST", "PUT", "DELETE"]:
            with self.subTest(method=method):
                self.assertEqual(self.request(method, path="/", scoped=False)[0], 404)

    def test_two_instances_and_sibling_port_cannot_overwrite_or_replay_cookie_alone(self):
        second = Application(self.app.inventory, self.github, static_root=self.root, logger=self.logs.append)
        server = CockpitServer(second)
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
        thread.start()
        def close_second():
            second.close(); server.shutdown(); server.server_close(); thread.join(1)
        self.addCleanup(close_second)
        jar = http.cookiejar.CookieJar()
        jar.set_cookie(http.cookiejar.Cookie(0, COOKIE, "legacy-fixture", None, False, "127.0.0.1",
            False, False, "/", True, False, None, True, None, None, {}, False))
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))
        origins = ["http://" + self.host, f"http://127.0.0.1:{server.server_address[1]}"]
        for app, origin in zip((self.app, second), origins):
            request = urllib.request.Request(origin + "/api/bootstrap", method="POST", headers={
                "Origin": origin, "X-Cockpit-Bootstrap": app._nonce, "X-Cockpit-CSRF": app._nonce})
            with opener.open(request, timeout=1) as response:
                self.assertEqual(response.status, 204)
        self.assertNotEqual(self.app._scope, second._scope)
        self.assertEqual({cookie.path for cookie in jar}, {self.app.scope_path, second.scope_path})
        for app, origin in zip((self.app, second), origins):
            with opener.open(origin + app.scope_path + "api/snapshot", timeout=1) as response:
                self.assertEqual(json.loads(response.read())["schema"], "cockpit/v1")
        ordinary = urllib.request.Request(origins[1] + "/unrelated")
        jar.add_cookie_header(ordinary)
        self.assertFalse(ordinary.has_header("Cookie"))
        # Even when explicitly replayed, the cookie alone never reveals scope.
        self.cookie = f"{COOKIE}={self.app._session}"
        self.assertEqual(self.request(scoped=False)[0], 404)
        wrong_scope = urllib.request.Request(origins[1] + self.app.scope_path + "api/snapshot")
        jar.add_cookie_header(wrong_scope)
        self.assertTrue(wrong_scope.has_header("Cookie"))
        with self.assertRaises(urllib.error.HTTPError) as error:
            opener.open(wrong_scope, timeout=1)
        self.assertEqual(error.exception.code, 404)
        error.exception.close()
        self.cookie = f"{COOKIE}={second._session}"
        self.assertEqual(self.request()[0], 401)
        self.cookie = f"{COOKIE}={self.app._session}"
        self.assertEqual(self.request()[0], 200)

    def test_session_required_on_all_ordinary_routes(self):
        for route in ["/", "/api/session", "/api/snapshot", "/api/panels/prs", "/events",
                      "/assets/fixture.js", "/bootstrap?launch=x"]:
            with self.subTest(route=route):
                self.assertEqual(self.request(path=route)[0], 401)
        for route in ["/bootstrap", "/bootstrap.js"]:
            status, headers, body = self.request(path=route)
            self.assertEqual(status, 200)
            self.assertNotIn(self.app._nonce.encode(), body)
            self.assertEqual(headers["Content-Security-Policy"], CSP)
            self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_bootstrap_csrf_origin_replay_and_expiry(self):
        for extra in [[], [("Origin", "http://" + self.host)], [("Origin", "http://evil.example"),
                       ("X-Cockpit-CSRF", self.app._nonce)], [("Origin", "http://" + self.host), ("X-Cockpit-CSRF", "é")]]:
            self.assertEqual(self.request("POST", "/api/bootstrap", authenticated=False, headers=[
                ("Host", self.host), ("X-Cockpit-Bootstrap", self.app._nonce)] + extra)[0], 403)
        self.bootstrap()
        self.assertEqual(self.request("POST", "/api/bootstrap", headers=[("Host", self.host),
            ("Origin", "http://" + self.host), ("X-Cockpit-Bootstrap", self.app._nonce),
            ("X-Cockpit-CSRF", self.app._nonce)])[0], 403)
        self.app._nonce_used = False; self.app._nonce_expires = 0
        self.assertFalse(self.app.bootstrap(self.app._nonce, self.app._nonce))

    def test_bootstrap_post_with_a_bare_query_marker_is_refused_without_consuming_the_nonce(self):
        launch = [("Host", self.host), ("Origin", "http://" + self.host),
                  ("X-Cockpit-Bootstrap", self.app._nonce), ("X-Cockpit-CSRF", self.app._nonce)]
        for path in ["/api/bootstrap?", "/api/bootstrap?x=1"]:
            with self.subTest(path=path):
                status, headers, _body = self.request("POST", path, authenticated=False, scoped=False, headers=launch)
                self.assertEqual(status, 404)
                self.assertNotIn("Set-Cookie", headers)
        self.assertFalse(self.app._nonce_used)
        self.bootstrap()

    def test_concurrent_bootstrap_consumes_nonce_once(self):
        barrier = threading.Barrier(2)
        outcomes = []
        def run():
            barrier.wait()
            outcomes.append(self.request("POST", "/api/bootstrap", authenticated=False, headers=[
                ("Host", self.host), ("Origin", "http://" + self.host),
                ("X-Cockpit-Bootstrap", self.app._nonce), ("X-Cockpit-CSRF", self.app._nonce)])[0])
        threads = [threading.Thread(target=run) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(1)
        self.assertEqual(sorted(outcomes), [204, 403])

    def test_every_non_get_including_unknown_methods_needs_csrf(self):
        self.bootstrap()
        for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD", "TRACE", "MADEUP"]:
            with self.subTest(method=method):
                self.assertEqual(self.request(method)[0], 403)
                self.assertEqual(self.request(method, headers=[("Host", self.host), ("Origin", "http://" + self.host),
                                  ("X-Cockpit-CSRF", "é")])[0], 403)
                self.assertEqual(self.request(method, headers=[("Host", self.host), ("Origin", "http://" + self.host),
                                  ("X-Cockpit-CSRF", self.app._csrf)])[0], 405)
        status, _, body = self.request(path="/api/session")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"csrf": self.app._csrf})
        self.assertNotIn(self.app._session.encode(), body)

    def test_framing_and_body_limits(self):
        self.bootstrap()
        for headers, expected in [([("Content-Length", "1"), ("Content-Length", "1")], 400),
                                  ([("Transfer-Encoding", "chunked")], 400),
                                  ([("Content-Length", "n/a")], 400), ([("Content-Length", "4097")], 413)]:
            self.assertEqual(self.request("POST", headers=[("Host", self.host)] + headers)[0], expected)

    def test_fleet_refresh_is_bodyless_fixed_source_and_requires_full_session_boundary(self):
        route = "/api/fleet/refresh"
        self.assertEqual(self.request("POST", route)[0], 401)
        self.bootstrap()
        headers = [("Host", self.host), ("Origin", "http://" + self.host), ("X-Cockpit-CSRF", self.app._csrf)]
        self.assertEqual(self.request("POST", route, headers=headers)[0], 503)
        self.app.scheduler.register("audit_only", lambda deadline: Sample({"fixture": True}))
        self.app.register_panel("fleet", "audit_only")
        with patch.object(self.app.scheduler, "refresh", wraps=self.app.scheduler.refresh) as refresh:
            for supplied, status in [([], 403), (headers[1:], 403), (headers[:-1], 403),
                                     (headers + [("Origin", "http://foreign.invalid")], 403),
                                     (headers + [("X-Cockpit-CSRF", self.app._csrf)], 403),
                                     (headers + [("Content-Length", "1")], 400)]:
                self.assertEqual(self.request("POST", route, headers=supplied)[0], status)
            self.assertEqual(self.request("POST", route + "?repo=other/repo", headers=headers)[0], 400)
            self.assertEqual(self.request("PUT", route, headers=headers)[0], 405)
            self.assertEqual(self.request("GET", route, headers=headers)[0], 404)
            refresh.assert_not_called()
            self.assertEqual(self.request("POST", route, headers=headers)[0], 202)
            refresh.assert_called_once_with("audit_only")

    def test_fleet_initial_dispatch_refresh_coalescing_failure_backoff_and_recovery_over_http(self):
        self.bootstrap()
        clock, release, calls = Clock(), threading.Event(), []
        self.addCleanup(release.set)
        self.app.scheduler.close()
        self.app.scheduler = Scheduler(workers=1, clock=clock, monotonic=clock, changed=self.app.publish)
        def fetch(deadline):
            calls.append(deadline)
            if len(calls) == 1:
                release.wait(2)
                raise ClientError("source_failed")
            return Sample({"fixture": "recovered"})
        self.app.scheduler.register("fleet", fetch, hot_interval=1800, idle_interval=1800, timeout=180, max_backoff=7200)
        self.app.register_panel("fleet", "fleet")
        self.app.scheduler.tick()
        wait_until(lambda: len(calls) == 1)
        envelope = json.loads(self.request(path="/api/panels/fleet")[2])["envelope"]
        self.assertTrue(envelope["in_flight"])
        self.assertIsNone(envelope["data"])
        self.assertIsNone(envelope["observed_at"])
        headers = [("Host", self.host), ("Origin", "http://" + self.host), ("X-Cockpit-CSRF", self.app._csrf)]
        for _ in range(4):
            self.assertEqual(self.request("POST", "/api/fleet/refresh", headers=headers)[0], 202)
            self.app.scheduler.tick()
        self.assertEqual(len(calls), 1)
        release.set()
        wait_until(lambda: not self.app.scheduler.snapshot()["fleet"]["in_flight"])
        failed = json.loads(self.request(path="/api/panels/fleet")[2])["envelope"]
        self.assertTrue(failed["stale"])
        self.assertEqual(failed["retry_at"], 2800)
        self.assertIsNone(failed["observed_at"])
        self.assertEqual(self.request("POST", "/api/fleet/refresh", headers=headers)[0], 202)
        self.app.scheduler.tick()
        self.assertEqual(len(calls), 1)
        clock.now = 2800
        self.app.scheduler.tick()
        wait_until(lambda: not self.app.scheduler.snapshot()["fleet"]["in_flight"])
        restored = json.loads(self.request(path="/api/panels/fleet")[2])["envelope"]
        self.assertFalse(restored["stale"])
        self.assertEqual(restored["observed_at"], 2800)
        self.assertEqual(restored["data"], {"fixture": "recovered"})
        self.app.scheduler.tick()
        self.assertEqual(len(calls), 2)

    def test_sync_routes_bind_server_session_and_preserve_auth_and_csrf(self):
        self.bootstrap()
        calls = []
        state = {"schema": "cockpit-sync/v1", "phase": "previewing", "preview": None, "run": None, "error": None}
        def action(session, payload):
            calls.append((session, payload))
            return state
        self.app.sync = SimpleNamespace(preview=action, confirm=action, cancel=action,
                                        snapshot=lambda session: state, close=lambda: None)
        headers = [("Host", self.host), ("Origin", "http://" + self.host),
                   ("X-Cockpit-CSRF", self.app._csrf), ("Content-Type", "application/json")]
        body = b'{"repos":["owner/consumer"]}'
        for name in ("preview", "confirm", "cancel"):
            reply = self.request("POST", "/api/sync/" + name,
                                 headers=headers + [("Content-Length", str(len(body)))], body=body)
            self.assertEqual(reply[0], 202)
            self.assertEqual(json.loads(reply[2]), state)
        self.assertTrue(all(session == self.app._session for session, payload in calls))
        self.assertEqual(calls[0][1], {"repos": ["owner/consumer"]})
        self.assertEqual(json.loads(self.request()[2])["sync"], state)
        for bad_headers, authenticated, expected in [(headers, False, 401), (headers[:2], True, 403),
                ([("Host", self.host), ("Origin", "https://foreign.invalid")], True, 403)]:
            self.assertEqual(self.request("POST", "/api/sync/confirm", authenticated=authenticated,
                headers=bad_headers + [("Content-Length", str(len(body)))], body=body)[0], expected)
        self.assertEqual(len(calls), 3)

    def test_sync_routes_reject_ambiguous_json_framing_and_arbitrary_commands(self):
        self.bootstrap()
        calls = []
        self.app.sync = SimpleNamespace(preview=lambda *args: calls.append(args),
                                        snapshot=lambda session: None, close=lambda: None)
        headers = [("Host", self.host), ("Origin", "http://" + self.host),
                   ("X-Cockpit-CSRF", self.app._csrf), ("Content-Type", "application/json")]
        for body in (b'[]', b'{"repos":[],"repos":[]}', b'{"x":NaN}', b'{"x":Infinity}', b'{"x":1e9999}', b'not-json', b'\xff'):
            self.assertEqual(self.request("POST", "/api/sync/preview", headers=headers +
                [("Content-Length", str(len(body)))], body=body)[0], 400)
        for route in ("/api/sync/preview?command=push", "/api/sync/confirm?repo=evil"):
            self.assertEqual(self.request("POST", route, headers=headers + [("Content-Length", "2")], body=b'{}')[0], 400)
        self.assertEqual(self.request("POST", "/api/sync/execute", headers=headers)[0], 405)
        self.assertEqual(self.request("POST", "/api/sync/preview", headers=headers + [("Content-Length", "4097")])[0], 413)
        self.assertEqual(self.request("POST", "/api/sync/preview", headers=headers + [("Transfer-Encoding", "chunked")])[0], 400)
        with patch("mergepath.cockpit.server.SYNC_BODY_SECONDS", 0.03):
            before = time.monotonic()
            self.assertEqual(self.request("POST", "/api/sync/preview", headers=headers +
                [("Content-Length", "2")], body=b'{')[0], 400)
            self.assertLess(time.monotonic() - before, 0.5)
        self.assertEqual(calls, [])
        self.app.sync = None
        self.assertEqual(self.request("POST", "/api/sync/preview", headers=headers + [("Content-Length", "2")], body=b'{}')[0], 503)

    def test_real_shell_and_local_assets_require_session_and_keep_csp(self):
        self.app.static_root = ROOT / "mergepath/cockpit"
        for route in ["/", "/assets/app.js", "/assets/components.js", "/assets/cockpit.css",
                      "/assets/fonts/local-fonts.css", "/assets/fonts/2c32b9b3ee358c11.woff2"]:
            self.assertEqual(self.request(path=route, authenticated=False)[0], 401)
        self.bootstrap()
        for route in ["/", "/assets/app.js", "/assets/components.js", "/assets/cockpit.css",
                      "/assets/fonts/local-fonts.css", "/assets/fonts/2c32b9b3ee358c11.woff2"]:
            status, headers, body = self.request(path=route)
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Security-Policy"], CSP)
            self.assertTrue(body)
            self.assertNotIn(TOKEN.encode(), body)
        self.assertEqual(self.request(path="/assets/fonts/manifest.json")[0], 404)
        self.assertEqual(self.request(path="/assets/fonts/instrumentsans-OFL.txt")[0], 404)
        self.assertEqual(self.github.budget(), {})

    def test_font_binaries_and_licenses_match_supplied_provenance(self):
        fonts = ROOT / "mergepath/cockpit/assets/fonts"
        manifest = json.loads((fonts / "manifest.json").read_text())
        for asset in manifest["assets"] + manifest["licenses"]:
            path = fonts / asset["file"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), asset["sha256"])
        css = (fonts / "local-fonts.css").read_text()
        self.assertNotIn("https:", css)
        self.assertNotIn("http:", css)
        for asset in manifest["assets"]:
            self.assertIn(asset["file"], css)
        self.assertNotIn("/assets/", css)

    def test_safe_static_refuses_sources_traversal_and_symlink_escape(self):
        self.bootstrap()
        (self.root / "assets" / "escape.html").symlink_to(ROOT / "README.md")
        for route in ["/assets/secret.py", "/server.py", "/assets/../index.html", "/assets/%2e%2e/index.html",
                      "/assets/%252e%252e/index.html", "/assets/escape.html", "/assets/", "/assets/%00.js"]:
            with self.subTest(route=route): self.assertEqual(self.request(path=route)[0], 404)
        self.assertEqual(self.request(path="/")[0], 200)
        self.assertEqual(self.request(path="/assets/fixture.js")[0], 200)
        (self.root / "index.html").unlink()
        self.assertEqual(json.loads(self.request(path="/")[2]), {"error": "visual_shell_unavailable"})

    def test_invalid_retry_never_breaks_authenticated_snapshot_or_sse(self):
        self.bootstrap()
        error = ClientError("secondary_limit", 120)
        error.retry_after = float("inf")
        def failed(deadline):
            raise error
        self.app.scheduler.register("bad_retry", failed)
        self.app.scheduler.register("healthy", lambda deadline: Sample({"visible": True}))
        self.app.scheduler.tick()
        wait_until(lambda: all(envelope["attempted_at"] is not None and not envelope["in_flight"]
                               for envelope in self.app.scheduler.snapshot().values()))
        status, _, body = self.request()
        self.assertEqual(status, 200)
        sources = json.loads(body)["sources"]
        self.assertEqual(sources["healthy"]["data"], {"visible": True})
        self.assertEqual(sources["bad_retry"]["error"], "secondary_limit")
        self.assertTrue(math.isfinite(sources["bad_retry"]["retry_at"]))
        response = self.request(path="/events", stream=True)
        self.assertEqual(response.status, 200)
        for _ in range(6):
            line = response.readline().decode()
            if line.startswith("data: "):
                self.assertEqual(json.loads(line[6:])["sources"], sources)
                break
        else:
            self.fail("SSE initial snapshot unavailable")
        response.close()

    def test_snapshot_filter_and_credentials_redaction(self):
        self.bootstrap()
        self.app.scheduler.register("fixture", lambda deadline: Sample({"message": TOKEN + self.app._session + self.app._nonce + self.app._scope}))
        self.app.scheduler.tick()
        wait_until(lambda: not self.app.scheduler.snapshot()["fixture"]["in_flight"])
        status, _, body = self.request(path="/api/snapshot?repo=a%2Fb")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual([item["repo"] for item in payload["repositories"]], ["a/b"])
        self.assertEqual(payload["sources"]["fixture"]["data"]["message"], "[redacted]" * 4)
        for route in ["/api/snapshot?repo=evil/repo", "/api/snapshot?repo=a/b&repo=a/b", "/api/snapshot?token=x"]:
            self.assertEqual(self.request(path=route)[0], 400)

    def test_fixed_panel_routes_initial_unknown_and_http_boundary(self):
        self.bootstrap()
        expected = {"data": None, "observed_at": None, "attempted_at": None, "stale": True,
                    "error": "unavailable", "retry_at": None, "in_flight": False}
        for panel in ("prs", "ci", "agents", "history", "fleet", "budget"):
            status, headers, body = self.request(path="/api/panels/" + panel)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), {"schema": "cockpit-panel/v1", "panel": panel,
                                              "source": None, "envelope": expected})
            self.assertEqual(headers["Content-Security-Policy"], CSP)
        self.assertEqual(self.request(path="/api/panels/prs", authenticated=False)[0], 401)
        self.assertEqual(self.request(path="/api/panels/prs", headers=[("Host", "evil.example")])[0], 403)
        self.assertEqual(self.request(path="/api/panels/prs", headers=[("Host", self.host),
                         ("Origin", "https://evil.example")])[0], 403)
        for route in ["/api/panels/unknown", "/api/panels/fixture", "/api/panels/prs/", "/api/panels/%70rs"]:
            self.assertEqual(self.request(path=route)[0], 404)
        for query in ["source=fixture", "repo=a/b", "token=x", "source=prs&source=ci"]:
            self.assertEqual(self.request(path="/api/panels/prs?" + query)[0], 400)
        self.assertEqual(self.github.budget(), {})

    def test_two_panels_share_one_trusted_source_without_endpoint_fetches(self):
        self.bootstrap()
        calls = []
        def fetch(deadline):
            calls.append(deadline)
            return Sample({"runs": [1]})
        self.app.scheduler.register("fixture_agents", fetch)
        for panel in ("agents", "history"):
            self.app.register_panel(panel, "fixture_agents")
            payload = json.loads(self.request(path="/api/panels/" + panel)[2])
            self.assertEqual(payload["source"], "fixture_agents")
            self.assertIsNone(payload["envelope"]["observed_at"])
            self.assertEqual(payload["envelope"]["error"], "unavailable")
        self.assertEqual(calls, [])
        for panel, source in [("unknown", "fixture_agents"), ("prs", "missing"), ("prs", None)]:
            with self.assertRaisesRegex(ValueError, "invalid_panel_source"):
                self.app.register_panel(panel, source)
        with self.assertRaisesRegex(ValueError, "duplicate_panel"):
            self.app.register_panel("agents", "fixture_agents")
        self.app.scheduler.tick()
        wait_until(lambda: not self.app.scheduler.snapshot()["fixture_agents"]["in_flight"])
        envelopes = []
        for _ in range(2):
            for panel in ("agents", "history"):
                envelopes.append(json.loads(self.request(path="/api/panels/" + panel)[2])["envelope"])
        self.assertTrue(all(item == envelopes[0] for item in envelopes))
        self.assertEqual(envelopes[0]["data"], {"runs": [1]})
        self.assertFalse(envelopes[0]["stale"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(list(self.app.snapshot()["sources"]), ["fixture_agents"])

    def test_panel_last_good_stale_envelope_reuses_snapshot_redaction(self):
        self.bootstrap()
        calls = []
        secrets = [TOKEN, self.app._nonce, self.app._session, self.app._csrf, self.app._scope]
        def fetch(deadline):
            calls.append(deadline)
            if len(calls) == 2:
                raise ClientError("fixture_failed", 120)
            return Sample({"nested": {"message": "".join(secrets)}})
        self.app.scheduler.register("fixture_prs", fetch)
        self.app.register_panel("prs", "fixture_prs")
        self.app.scheduler.tick()
        wait_until(lambda: not self.app.scheduler.snapshot()["fixture_prs"]["in_flight"])
        first = json.loads(self.request(path="/api/panels/prs")[2])["envelope"]
        self.assertEqual(first["data"], {"nested": {"message": "[redacted]" * 5}})
        self.app.scheduler.refresh("fixture_prs")
        self.app.scheduler.tick()
        wait_until(lambda: not self.app.scheduler.snapshot()["fixture_prs"]["in_flight"])
        status, _, body = self.request(path="/api/panels/prs")
        self.assertEqual(status, 200)
        current = json.loads(body)["envelope"]
        self.assertEqual(current["data"], first["data"])
        self.assertEqual(current["observed_at"], first["observed_at"])
        self.assertTrue(current["stale"])
        self.assertEqual(current["error"], "source_failed")
        for secret in secrets:
            self.assertNotIn(secret.encode(), body)
        self.assertEqual(current, self.app.snapshot()["sources"]["fixture_prs"])
        self.assertEqual(len(calls), 2)

    def test_arbitrary_client_error_text_never_enters_http_source_envelopes(self):
        self.bootstrap()
        private = "upstream /private/fixture unrelated-credential-do-not-publish"
        def fetch(deadline):
            raise ClientError(private, 120)
        self.app.scheduler.register("fixture_error", fetch)
        self.app.register_panel("prs", "fixture_error")
        self.app.scheduler.tick()
        wait_until(lambda: not self.app.scheduler.snapshot()["fixture_error"]["in_flight"])
        for route in ["/api/snapshot", "/api/panels/prs"]:
            status, _, body = self.request(path=route)
            self.assertEqual(status, 200)
            self.assertNotIn(private.encode(), body)
            payload = json.loads(body)
            envelope = payload["sources"]["fixture_error"] if route == "/api/snapshot" else payload["envelope"]
            self.assertEqual(envelope["error"], "source_failed")
            self.assertIsNone(envelope["data"])
            self.assertTrue(envelope["stale"])
        self.assertNotIn(private, "".join(self.logs))

    def test_sse_snapshot_heartbeat_reconnect_and_update(self):
        self.bootstrap()
        response = self.request(path="/events", stream=True)
        lines = []
        while len(lines) < 20:
            line = response.readline().decode(); lines.append(line)
            if line == "event: heartbeat\n": break
        self.assertIn("retry: 2000\n", lines)
        self.assertIn("event: snapshot\n", lines)
        self.assertIn("event: heartbeat\n", lines)
        response.close()
        self.app.publish()
        response = self.request(path="/events", headers=[("Host", self.host), ("Last-Event-ID", "9999")], stream=True)
        text = "".join(response.readline().decode() for _ in range(6))
        self.assertIn("id: 1\n", text)
        self.assertIn('"schema":"cockpit/v1"', text)
        response.close()
        self.assertEqual(self.github.budget(), {})

    def test_asset_burst_waits_for_capacity_without_exceeding_eight_handlers(self):
        self.bootstrap()
        wait_until(lambda: self.server._request_slots._value == 8)
        slots = AdmissionSlots()
        self.server._request_slots = slots
        entered = [threading.Event() for _ in range(8)]
        release = [threading.Event() for _ in range(8)]
        lock = threading.Lock()
        active, peak, sequence = 0, 0, 0
        original_handler = self.server.RequestHandlerClass
        results = [None] * 9

        class BurstHandler(original_handler):
            def _static(handler, path):
                nonlocal active, peak, sequence
                with lock:
                    index = sequence
                    sequence += 1
                    active += 1
                    peak = max(peak, active)
                try:
                    if index < 8:
                        entered[index].set()
                        if not release[index].wait(2):
                            raise AssertionError("fixture asset release expired")
                    super()._static(path)
                finally:
                    with lock:
                        active -= 1

        self.server.RequestHandlerClass = BurstHandler
        def read_asset(index):
            try:
                results[index] = self.request(path="/assets/fixture.js")
            except (OSError, http.client.HTTPException) as error:
                results[index] = type(error).__name__
        clients = [threading.Thread(target=read_asset, args=(index,), daemon=True) for index in range(9)]
        try:
            for index, client in enumerate(clients[:8]):
                client.start()
                self.assertTrue(entered[index].wait(1))
            self.assertTrue(all(event.wait(1) for event in entered))
            self.assertEqual(peak, 8)
            clients[8].start()
            self.assertTrue(slots.saturated.wait(1))
            self.assertFalse(slots.admission_finished.wait(0.025), "saturated asset was immediately refused")
            release[0].set()
            clients[8].join(1)
            self.assertFalse(clients[8].is_alive())
            self.assertIsInstance(results[8], tuple)
            self.assertEqual(results[8][0], 200)
            self.assertEqual(results[8][2], (self.root / "assets/fixture.js").read_bytes())
        finally:
            for event in release: event.set()
            for client in clients:
                if client.ident is not None: client.join(1)
        self.assertTrue(all(isinstance(result, tuple) and result[0] == 200 for result in results))
        self.assertLessEqual(peak, 8)
        wait_until(lambda: slots._value == 8)

    def test_saturated_admission_times_out_and_shutdown_remains_bounded(self):
        self.bootstrap()
        wait_until(lambda: self.server._request_slots._value == 8)
        slots = AdmissionSlots()
        self.server._request_slots = slots
        for _ in range(8): self.assertTrue(slots.acquire(blocking=False))
        result = []
        def read_asset():
            started = time.monotonic()
            try:
                result.append(("response", self.request(path="/assets/fixture.js"), time.monotonic() - started))
            except (OSError, http.client.HTTPException) as error:
                result.append((type(error).__name__, None, time.monotonic() - started))
        client = threading.Thread(target=read_asset, daemon=True)
        try:
            client.start()
            self.assertTrue(slots.saturated.wait(1))
            shutdown_started = time.monotonic()
            self.server.shutdown()
            self.assertLess(time.monotonic() - shutdown_started, 1.25)
            client.join(1)
            self.assertFalse(client.is_alive())
            self.assertEqual(len(result), 1)
            self.assertIn(result[0][0], ("RemoteDisconnected", "ConnectionResetError"))
            self.assertGreaterEqual(result[0][2], 0.4)
            self.assertLess(result[0][2], 1.25)
            self.assertEqual(slots._value, 0)
        finally:
            for _ in range(8): slots.release()
            client.join(1)
        self.assertEqual(slots._value, 8)

    def test_admission_slot_returns_after_dispatch_or_handler_failure(self):
        wait_until(lambda: self.server._request_slots._value == 8)
        base = CockpitServer.__mro__[1]
        request = object()
        with patch.object(base, "process_request", side_effect=RuntimeError("fixture dispatch failure")), \
             patch.object(self.server, "shutdown_request") as close:
            self.server.process_request(request, ("127.0.0.1", 1))
        close.assert_called_once_with(request)
        self.assertEqual(self.server._request_slots._value, 8)
        self.assertTrue(self.server._request_slots.acquire(blocking=False))
        with patch.object(base, "process_request_thread", side_effect=RuntimeError("fixture handler failure")):
            with self.assertRaises(RuntimeError):
                self.server.process_request_thread(request, ("127.0.0.1", 1))
        self.assertEqual(self.server._request_slots._value, 8)

    def test_sse_connection_bound_and_shutdown(self):
        self.bootstrap()
        streams = [self.request(path="/events", stream=True) for _ in range(2)]
        self.assertEqual(self.request(path="/events")[0], 503)
        self.app.close()
        for stream in streams: stream.close()

    def test_sse_slot_is_released_when_the_client_closes_between_heartbeats(self):
        # #1844: a page that went away kept its stream slot until the next heartbeat write failed,
        # so a quick return found both slots held and sat on Reconnecting. With heartbeats a minute
        # apart, only noticing the closed peer can free the slot in time.
        self.app.heartbeat = 60
        self.bootstrap()
        streams = [self.request(path="/events", stream=True) for _ in range(2)]
        for stream in streams:
            self.assertEqual(stream.status, 200); stream.readline()
        self.assertEqual(self.request(path="/events")[0], 503)
        streams[0].close()
        deadline, status = time.monotonic() + 5, 503
        while status == 503 and time.monotonic() < deadline:
            time.sleep(0.2)
            reopened = self.request(path="/events", stream=True); status = reopened.status
            if status != 200: reopened.read(); reopened.close()
        self.assertEqual(status, 200, "a closed stream's slot is released within seconds, not at the heartbeat")
        # The open stream keeps its slot: a live page is never evicted.
        self.assertEqual(self.request(path="/events")[0], 503)
        reopened.close(); streams[1].close()

    def test_logs_and_errors_never_echo_secrets_paths_or_headers(self):
        self.bootstrap()
        self.request(path="/" + self.app._session + "?credential=" + TOKEN)
        self.request(headers=[("Host", self.app._nonce)])
        log = "\n".join(self.logs)
        for secret in [TOKEN, self.app._nonce, self.app._session, self.app._csrf, self.app._scope]:
            self.assertNotIn(secret, log)
        self.assertTrue(all(line.startswith("request status=") for line in self.logs))


class InventoryAndLauncherTests(unittest.TestCase):
    def test_inventory_uses_fixed_existing_yq_and_freezes_hub_plus_consumers(self):
        calls = []
        def run(*args, **kwargs):
            calls.append((args, kwargs))
            return SimpleNamespace(stdout='[{"name":"one", "repo":"owner/one"}]')
        inventory = load_inventory(Path("/fixture"), run)
        self.assertIsInstance(inventory, tuple)
        self.assertEqual(inventory[0].repo, HUB)
        self.assertEqual(calls[0][0][0], ["yq", "-o=json", ".consumers", "/fixture/.mergepath-sync.yml"])
        self.assertEqual(calls[0][1]["timeout"], 10)
        with self.assertRaises(Exception): inventory[0].repo = "changed"

    def test_invalid_inventory_never_reports_empty_fleet(self):
        for data in [None, [], [{"name": "x", "repo": "../secret"}], [{"name":"x","repo":"owner/x"}]*2,
                     [{"name":"mergepath","repo":HUB}], [{"name":"x","repo":"OWNER/X"}, {"name":"y","repo":"owner/x"}]]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                load_inventory(Path("/fixture"), lambda *args, **kwargs: SimpleNamespace(stdout=json.dumps(data)))
        with self.assertRaisesRegex(ValueError, "manifest_inventory_unavailable"):
            load_inventory(Path("/fixture"), lambda *args, **kwargs: (_ for _ in ()).throw(subprocess.TimeoutExpired("yq", 10)))

    def test_launcher_calls_cache_check_only_and_scrubs_author_and_ambient(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / "scripts").mkdir(); (root / "mergepath" / "cockpit").mkdir(parents=True)
            launcher = root / "scripts" / "cockpit.sh"
            launcher.write_bytes((ROOT / "scripts" / "cockpit.sh").read_bytes())
            (root / "scripts" / "op-preflight.sh").write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" > "$COCKPIT_TEST_CALLS"\n'
                'if [ "${COCKPIT_TEST_CACHE_FAIL:-0}" = 1 ]; then exit 1; fi\n'
                'printf "export OP_PREFLIGHT_REVIEWER_PAT=fixture-reviewer-credential\\nexport OP_PREFLIGHT_AUTHOR_PAT=fixture-author-credential\\n"\n')
            (root / "scripts" / "op-preflight.sh").chmod(0o755)
            (root / "mergepath" / "cockpit" / "__main__.py").write_text(
                'import os\nassert os.environ["OP_PREFLIGHT_REVIEWER_PAT"] == "fixture-reviewer-credential"\n'
                'assert not any(name in os.environ for name in ["OP_PREFLIGHT_AUTHOR_PAT", "GH_TOKEN", "GITHUB_TOKEN"])\n'
                'print("fixture server launched")\n')
            calls = root / "calls"
            env = {**os.environ, "COCKPIT_TEST_CALLS": str(calls), "GH_TOKEN": "fixture-ambient", "GITHUB_TOKEN": "fixture-ambient"}
            result = subprocess.run(["bash", "-x", str(launcher), "--port", "0"], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls.read_text().strip(), "--agent codex --check --print-exports")
            self.assertNotIn(TOKEN, result.stdout + result.stderr)
            self.assertNotIn("fixture-author-credential", result.stdout + result.stderr)
            # Stock macOS /bin/bash is 3.2 and treats empty arrays under nounset differently.
            result = subprocess.run(["/bin/bash", str(launcher), "--port", "0"], env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls.read_text().strip(), "--agent codex --check --print-exports")
            env["COCKPIT_TEST_CACHE_FAIL"] = "1"
            result = subprocess.run(["bash", str(launcher)], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("fixture server launched", result.stdout)

    def test_shutdown_stops_audit_before_waiting_on_sync_preview(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        events = []
        app = SimpleNamespace(stopping=threading.Event(), scheduler=SimpleNamespace(close=lambda: events.append("scheduler")),
                              close=lambda: events.append("sync"))
        fleet = SimpleNamespace(close=lambda: events.append("fleet"))
        main.close_runtime(app, fleet)
        self.assertTrue(app.stopping.is_set())
        self.assertEqual(events, ["scheduler", "fleet", "sync"])

    def test_fleet_constructor_refusal_keeps_unrelated_panels_and_refuses_sync(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        fleet_module = importlib.import_module("mergepath.cockpit.fleet")
        panels = {"ci": "ci", "prs": "prs", "budget": "actions",
                  "history": "agents", "agents": "live_agents"}
        boundaries = {"CIProvider": "ci", "PRProvider": "prs", "ActionsProvider": "actions",
                      "AgentsProvider": "agents", "LiveAgentsProvider": "live_agents"}
        for fault in ("missing-tool", "workspace"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temp:
                applications, workspaces, thread_errors, output = [], [], [], io.StringIO()
                client = GitHubClient(TOKEN, transport=HTTPFixture())
                def application(*args, **kwargs):
                    app = Application(*args, **kwargs); applications.append(app); return app
                real_allocate = tempfile.mkdtemp
                def allocate(*args, **kwargs):
                    path = real_allocate(prefix="fixture-fleet-", dir=temp)
                    workspaces.append(Path(path)); return path
                def which(tool, *, path):
                    self.assertEqual(path, fleet_module.UTILITY_PATH)
                    return None if fault == "missing-tool" and tool == "gh" else "/bin/true"
                def opened(url):
                    app = applications[0]
                    wait_until(lambda: all(app.panel_snapshot(panel)["envelope"]["data"] is not None
                                           for panel in panels), timeout=2)
                    parts = urllib.parse.urlsplit(url); authority = "http://" + parts.netloc
                    fragment = urllib.parse.parse_qs(parts.fragment); nonce = fragment["launch"][0]
                    scope = "/s/" + fragment["scope"][0]
                    connection = http.client.HTTPConnection("127.0.0.1", int(parts.port), timeout=1)
                    try:
                        connection.request("POST", "/api/bootstrap", headers={"Origin": authority,
                            "X-Cockpit-Bootstrap": nonce, "X-Cockpit-CSRF": nonce})
                        response = connection.getresponse(); self.assertEqual(response.status, 204)
                        cookie = [v for k, v in response.getheaders() if k.lower() == "set-cookie"][-1].split(";", 1)[0]
                        response.read()
                        headers = {"Cookie": cookie}
                        connection.request("GET", scope + "/api/snapshot", headers=headers)
                        response = connection.getresponse(); self.assertEqual(response.status, 200)
                        snapshot = json.loads(response.read())
                        self.assertEqual(set(snapshot["sources"]), set(panels.values()) | {"api_author"})
                        self.assertEqual(snapshot["sources"]["api_author"]["data"]["error"], "cached_author_required")
                        self.assertIsNone(snapshot["sync"]); self.assertIsNone(app.sync)
                        for panel, source in panels.items():
                            connection.request("GET", scope + "/api/panels/" + panel, headers=headers)
                            response = connection.getresponse(); self.assertEqual(response.status, 200)
                            value = json.loads(response.read())
                            self.assertEqual(value["source"], source)
                            self.assertEqual(value["envelope"]["data"], {"fixture_read_boundary": source})
                            self.assertFalse(value["envelope"]["stale"])
                        connection.request("GET", scope + "/api/panels/fleet", headers=headers)
                        response = connection.getresponse(); self.assertEqual(response.status, 200)
                        missing = json.loads(response.read())
                        self.assertIsNone(missing["source"]); self.assertIsNone(missing["envelope"]["data"])
                        self.assertTrue(missing["envelope"]["stale"])
                        connection.request("GET", scope + "/api/session", headers=headers)
                        response = connection.getresponse(); self.assertEqual(response.status, 200)
                        csrf = json.loads(response.read())["csrf"]
                        connection.request("POST", scope + "/api/sync/preview", body="{}", headers={
                            **headers, "Origin": authority, "X-Cockpit-CSRF": csrf, "Content-Type": "application/json"})
                        response = connection.getresponse(); self.assertEqual(response.status, 503)
                        self.assertEqual(json.loads(response.read()), {"error": "sync_unavailable"})
                        self.assertNotIn(nonce, output.getvalue()); self.assertNotIn(csrf, output.getvalue())
                    finally:
                        connection.close()
                    raise KeyboardInterrupt  # Stop the actual local server normally.
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.object(main.GitHubClient, "from_environment", return_value=client))
                    stack.enter_context(patch.object(main, "load_inventory", return_value=(
                        Repository("mergepath", HUB, True), Repository("one", "fixture/one"))))
                    stack.enter_context(patch.object(main, "Application", side_effect=application))
                    stack.enter_context(patch.object(main, "AuthorBudgetProvider", return_value=author_fixture()))
                    # Replace only provider reads; keep real construction refusal,
                    # Application, Scheduler, authenticated HTTP and shutdown.
                    for name, source in boundaries.items():
                        fetch = lambda deadline, source=source: Sample({"fixture_read_boundary": source})
                        provider = fetch if name in ("CIProvider", "PRProvider") else SimpleNamespace(fetch=fetch)
                        stack.enter_context(patch.object(main, name, return_value=provider))
                    stack.enter_context(patch.object(main, "resolve_history_settings", return_value=((), {})))
                    stack.enter_context(patch.object(main, "load_reviewers", return_value=("fixture-reviewer",)))
                    stack.enter_context(patch.object(main, "resolve_live_directory", return_value=Path(temp) / "heartbeats"))
                    sync = stack.enter_context(patch.object(main, "SyncProvider", side_effect=AssertionError("sync must stay unavailable")))
                    stack.enter_context(patch.object(fleet_module.shutil, "which", side_effect=which))
                    stack.enter_context(patch.object(fleet_module.tempfile, "mkdtemp", side_effect=allocate))
                    if fault == "workspace":
                        stack.enter_context(patch.object(Path, "symlink_to", side_effect=OSError("fixture-private-workspace-failure")))
                    opener = stack.enter_context(patch.object(main, "open_browser", side_effect=opened))
                    stack.enter_context(patch.object(threading, "excepthook", side_effect=lambda args: thread_errors.append(args.exc_type.__name__)))
                    stack.enter_context(patch.dict(os.environ, {"OP_PREFLIGHT_AUTHOR_PAT": "fixture-author-secret",
                        "OP_PREFLIGHT_REVIEWER_PAT": TOKEN, "GH_TOKEN": "fixture-ambient-secret"}, clear=True))
                    stack.enter_context(contextlib.redirect_stdout(output)); stack.enter_context(contextlib.redirect_stderr(output))
                    self.assertEqual(main.main([]), 0, output.getvalue())
                    opener.assert_called_once(); sync.assert_not_called()
                    self.assertFalse(any(key in os.environ for key in ("OP_PREFLIGHT_AUTHOR_PAT", "OP_PREFLIGHT_REVIEWER_PAT", "GH_TOKEN")))
                self.assertTrue(applications[0].stopping.is_set()); self.assertEqual(thread_errors, [])
                self.assertTrue(all(not path.exists() for path in workspaces))
                self.assertEqual(len(workspaces), 0 if fault == "missing-tool" else 1)
                self.assertIn("Fleet audits unavailable", output.getvalue())
                for private in (TOKEN, temp, "fixture-private-workspace-failure", "fixture-author-secret", "fixture-ambient-secret",
                                applications[0]._scope, applications[0]._nonce, applications[0]._session, applications[0]._csrf):
                    self.assertNotIn(private, output.getvalue())
                self.assertRegex(output.getvalue(), r"Mergepath Cockpit: http://127\.0\.0\.1:\d+/\n")
                self.assertIn("Open that URL again in the browser it launched", output.getvalue())

    def test_launcher_agent_reaches_main_sync_provider_without_credentials(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            (root / "mergepath" / "cockpit").mkdir(parents=True)
            launcher = root / "scripts" / "cockpit.sh"
            launcher.write_bytes((ROOT / "scripts" / "cockpit.sh").read_bytes())
            preflight = root / "scripts" / "op-preflight.sh"
            preflight.write_text('#!/bin/bash\nprintf "%s\\n" "$*" > "$COCKPIT_TEST_CALLS"\n'
                                 'printf "export OP_PREFLIGHT_REVIEWER_PAT=fixture-reviewer-credential\\n"\n')
            preflight.chmod(0o755)
            # Execute the actual Python parser/construction path, stopping before
            # any server, provider worker or credential operation can start.
            (root / "mergepath" / "cockpit" / "__main__.py").write_text(
                'import importlib, json, sys, threading\n'
                'from contextlib import ExitStack\nfrom types import SimpleNamespace\n'
                'from unittest.mock import patch\n'
                f'sys.path.insert(0, {str(ROOT)!r})\n'
                'main = importlib.import_module("mergepath.cockpit.__main__")\n'
                'def sync(*args, agent="codex", **kwargs):\n'
                '    print(json.dumps({"agent":agent,"cache_dir":str(kwargs["cache_dir"])}))\n'
                '    return SimpleNamespace(close=lambda: None)\n'
                'scheduler = SimpleNamespace(register=lambda *a, **k: None, close=lambda: None)\n'
                'app = SimpleNamespace(stopping=threading.Event(), scheduler=scheduler,\n'
                '    register_panel=lambda *a: None, publish=lambda: None, close=lambda: None)\n'
                'with ExitStack() as stack:\n'
                '    stack.enter_context(patch.object(main.GitHubClient, "from_environment", return_value=SimpleNamespace(_token="fixture-only")))\n'
                '    stack.enter_context(patch.object(main, "load_inventory", return_value=()))\n'
                '    stack.enter_context(patch.object(main, "resolve_history_settings", return_value=((), {})))\n'
                '    stack.enter_context(patch.object(main, "load_reviewers", return_value=("fixture-reviewer",)))\n'
                '    stack.enter_context(patch.object(main, "Application", return_value=app))\n'
                '    for name in ("FleetProvider", "CIProvider", "LogExcerptCache", "PRProvider", "ActionsProvider", "AgentsProvider", "LiveAgentsProvider", "AuthorBudgetProvider"):\n'
                '        stack.enter_context(patch.object(main, name, return_value=SimpleNamespace(fetch=lambda deadline: None, close=lambda: None)))\n'
                '    stack.enter_context(patch.object(main, "SyncProvider", side_effect=sync))\n'
                '    stack.enter_context(patch.object(main, "CockpitServer", side_effect=ValueError("fixture-stop-before-server")))\n'
                '    raise SystemExit(main.main(sys.argv[1:]))\n')
            calls, cache = root / "calls", root / "cache"
            env = {**os.environ, "COCKPIT_TEST_CALLS": str(calls), "OP_PREFLIGHT_CACHE_DIR": str(cache),
                   "OP_PREFLIGHT_AGENT": "cursor"}
            for agent, arguments in [("codex", []), ("codex", ["--agent", "codex"]),
                                     ("claude", ["--agent", "claude"]), ("cursor", ["--agent", "cursor"])]:
                with self.subTest(agent=agent, arguments=arguments):
                    result = subprocess.run(["bash", str(launcher), *arguments], env=env,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(calls.read_text().strip(), f"--agent {agent} --check --print-exports")
                    self.assertEqual(json.loads(result.stdout), {"agent": agent, "cache_dir": str(cache.resolve())})
                    direct = subprocess.run([sys.executable, "-I", str(root / "mergepath" / "cockpit" / "__main__.py"),
                                             *arguments], env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(direct.returncode, 1, direct.stderr)
                    self.assertEqual(json.loads(direct.stdout), {"agent": agent, "cache_dir": str(cache.resolve())})
            calls.unlink()
            for arguments in (["--agent", "unknown"], ["--agent"]):
                result = subprocess.run(["bash", str(launcher), *arguments], env=env,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(calls.exists())
            result = subprocess.run([sys.executable, "-I", str(root / "mergepath" / "cockpit" / "__main__.py"),
                                     "--agent", "unknown"], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_launcher_resolves_settings_at_caller_before_changing_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root, caller = Path(temp) / "hub", Path(temp) / "caller"
            (root / "scripts").mkdir(parents=True)
            (root / "mergepath" / "cockpit").mkdir(parents=True)
            caller.mkdir()
            launcher = root / "scripts" / "cockpit.sh"
            launcher.write_bytes((ROOT / "scripts" / "cockpit.sh").read_bytes())
            preflight = root / "scripts" / "op-preflight.sh"
            preflight.write_text('#!/bin/bash\nprintf "called\\n" >> "$COCKPIT_TEST_CALLS"\n'
                                 'printf "export OP_PREFLIGHT_REVIEWER_PAT=fixture-reviewer-credential\\n"\n')
            preflight.chmod(0o755)
            (root / "mergepath" / "cockpit" / "__main__.py").write_text(
                'import argparse, json\nfrom pathlib import Path\n'
                'parser = argparse.ArgumentParser()\nparser.add_argument("--port")\nparser.add_argument("--agent")\n'
                'parser.add_argument("--actions-settings")\nparser.add_argument("--agents-settings")\nargs = parser.parse_args()\n'
                'path = Path(args.actions_settings or args.agents_settings)\n'
                'print(json.dumps({"path":str(path),"data":json.loads(path.read_text())}))\n')
            # These characters must remain literal argv/file content, not shell code.
            name = "settings $(touch injected-dollar) `touch injected-backtick` [x]; 'quote'.json"
            settings = caller / name
            settings.write_text('{"budget":42}')
            (root / name).write_text('{"budget":999}')  # Catch reading the wrong cwd, too.
            calls = Path(temp) / "calls"
            env = {**os.environ, "COCKPIT_TEST_CALLS": str(calls)}
            for shell, option, argument in [(shell, option, argument) for shell in ("bash", "/bin/bash") for option in ("--actions-settings", "--agents-settings") for argument in (name, str(settings))]:
                with self.subTest(shell=shell, option=option, argument=argument):
                    result = subprocess.run([shell, str(launcher), option, argument],
                                            cwd=caller, env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    value = json.loads(result.stdout)
                    self.assertTrue(Path(value["path"]).is_absolute())
                    self.assertEqual(Path(value["path"]).resolve(), settings.resolve())
                    self.assertEqual(value["data"]["budget"], 42)
            self.assertEqual(calls.read_text().splitlines(), ["called"] * 8)
            for directory in (root, caller):
                for marker in ("injected-dollar", "injected-backtick"):
                    self.assertFalse((directory / marker).exists())
            for arguments in (["--actions-settings", ""], ["--actions-settings"], ["--agents-settings", ""], ["--agents-settings"]):
                result = subprocess.run(["bash", str(launcher), *arguments], cwd=caller, env=env,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn("usage:", result.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["called"] * 8)

    def test_settings_are_bounded_regular_json_and_refuse_unsafe_inputs(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        self.assertEqual(main.load_settings_json(None), {})
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "settings with spaces.json"
            path.write_text('{"budget":42,"measurements":{}}')
            self.assertEqual(main.load_settings_json(path)["budget"], 42)
            for raw in [b'[]', b'{broken', b'{}'+b' '*65535, b'\xff', b'['*2000+b']'*2000]:
                path.write_bytes(raw)
                with self.subTest(raw=raw[:10]), self.assertRaises((ValueError, UnicodeError)):
                    main.load_settings_json(path)
            path.unlink(); os.mkfifo(path)
            with self.assertRaises(ValueError): main.load_settings_json(path)
            path.unlink(); path.symlink_to(Path(temp) / "missing")
            with self.assertRaises(OSError): main.load_settings_json(path)

    def test_history_reviewer_configuration_is_explicit_bounded_and_scrubbed(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        calls = []
        def read(argv, **kwargs):
            calls.append((argv, kwargs))
            return SimpleNamespace(stdout='["fixture-reviewer", "another-reviewer", "fixture-reviewer"]')
        with patch.dict(os.environ, {"GH_TOKEN": TOKEN, "OP_PREFLIGHT_AUTHOR_PAT": TOKEN}):
            reviewers = main.load_reviewers(ROOT, run=read)
        self.assertEqual(reviewers, ("fixture-reviewer", "another-reviewer"))
        self.assertEqual(calls[0][0][2], ".available_reviewers")
        self.assertEqual(calls[0][1]["timeout"], 5)
        self.assertNotIn(TOKEN, json.dumps(calls[0][1]["env"]))
        for raw in ('null', '{}', '[]', '["bad/name"]', '[true]', 'invalid', 'x'*16385):
            with self.subTest(raw=raw[:20]), self.assertRaises(ValueError):
                main.load_reviewers(ROOT, run=lambda *args, **kwargs: SimpleNamespace(stdout=raw))
        with self.assertRaises(ValueError):
            main.load_reviewers(ROOT, run=lambda *args, **kwargs: (_ for _ in ()).throw(OSError(TOKEN)))

    def test_fleet_constructor_refusal_keeps_unrelated_panels_and_cleans_partial_workspace(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        fleet_module = importlib.import_module("mergepath.cockpit.fleet")
        for fault in ("missing-tool", "workspace"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temp:
                applications, workspaces, output = [], [], io.StringIO()
                client = GitHubClient(TOKEN, transport=HTTPFixture())
                def application(*args, **kwargs):
                    app = Application(*args, **kwargs); applications.append(app); return app
                real_allocate = tempfile.mkdtemp
                def allocate(*args, **kwargs):
                    path = real_allocate(prefix="fixture-fleet-", dir=temp)
                    workspaces.append(Path(path)); return path
                def which(tool, *, path):
                    self.assertEqual(path, fleet_module.UTILITY_PATH)
                    return None if fault == "missing-tool" and tool == "gh" else "/bin/true"
                def opened(url):
                    parts = urllib.parse.urlsplit(url); authority = "http://" + parts.netloc
                    fragment = urllib.parse.parse_qs(parts.fragment); nonce = fragment["launch"][0]
                    connection = http.client.HTTPConnection("127.0.0.1", int(parts.port), timeout=1)
                    connection.request("POST", "/api/bootstrap", headers={"Origin": authority,
                        "X-Cockpit-Bootstrap": nonce, "X-Cockpit-CSRF": nonce})
                    response = connection.getresponse(); self.assertEqual(response.status, 204)
                    cookie = [v for k, v in response.getheaders() if k.lower() == "set-cookie"][-1].split(";", 1)[0]
                    response.read()
                    connection.request("GET", f"/s/{fragment['scope'][0]}/api/snapshot", headers={"Cookie": cookie})
                    response = connection.getresponse(); self.assertEqual(response.status, 200)
                    snapshot = json.loads(response.read()); connection.close()
                    self.assertIn("prs", snapshot["sources"]); self.assertNotIn("fleet", snapshot["sources"])
                    self.assertIn("actions", snapshot["sources"])
                    self.assertEqual(applications[0].panel_snapshot("budget")["source"], "actions")
                    self.assertIn("agents", snapshot["sources"]); self.assertIn("live_agents", snapshot["sources"])
                    self.assertEqual(applications[0].panel_snapshot("history")["source"], "agents")
                    self.assertEqual(applications[0].panel_snapshot("agents")["source"], "live_agents")
                    self.assertEqual(applications[0].panel_snapshot("prs")["source"], "prs")
                    missing = applications[0].panel_snapshot("fleet")
                    self.assertIsNone(missing["source"]); self.assertIsNone(missing["envelope"]["data"])
                    self.assertTrue(missing["envelope"]["stale"])
                    raise KeyboardInterrupt  # Stop the actual local server normally.
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.object(main.GitHubClient, "from_environment", return_value=client))
                    stack.enter_context(patch.object(main, "load_inventory", return_value=(
                        Repository("mergepath", HUB, True), Repository("one", "fixture/one"))))
                    stack.enter_context(patch.object(main, "Application", side_effect=application))
                    stack.enter_context(patch.object(main, "AuthorBudgetProvider", return_value=author_fixture()))
                    stack.enter_context(patch.object(main, "resolve_history_settings", return_value=((), {})))
                    stack.enter_context(patch.object(main, "load_reviewers", return_value=("fixture-reviewer",)))
                    stack.enter_context(patch.object(main, "AgentsProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}))))
                    stack.enter_context(patch.object(main, "LiveAgentsProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}))))
                    stack.enter_context(patch.object(main, "PRProvider", return_value=lambda deadline: Sample({})))
                    stack.enter_context(patch.object(fleet_module.shutil, "which", side_effect=which))
                    stack.enter_context(patch.object(fleet_module.tempfile, "mkdtemp", side_effect=allocate))
                    if fault == "workspace":
                        stack.enter_context(patch.object(Path, "symlink_to", side_effect=OSError("fixture-private-workspace-failure")))
                    opener = stack.enter_context(patch.object(main, "open_browser", side_effect=opened))
                    stack.enter_context(patch.dict(os.environ, {}, clear=True))
                    stack.enter_context(contextlib.redirect_stdout(output)); stack.enter_context(contextlib.redirect_stderr(output))
                    self.assertEqual(main.main([]), 0, output.getvalue())
                    opener.assert_called_once()
                self.assertTrue(applications[0].stopping.is_set())
                self.assertTrue(all(not path.exists() for path in workspaces))
                self.assertEqual(len(workspaces), 0 if fault == "missing-tool" else 1)
                self.assertIn("Fleet audits unavailable", output.getvalue())
                self.assertNotIn(TOKEN, output.getvalue())

    def test_browser_failure_never_exposes_fragment(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        output = io.StringIO()
        client = GitHubClient(TOKEN, transport=HTTPFixture())
        with patch.object(main.GitHubClient, "from_environment", return_value=client), \
             patch.object(main, "load_inventory", return_value=(Repository("mergepath", HUB, True),)), \
             patch.object(main, "AuthorBudgetProvider", return_value=author_fixture()), \
             patch.object(main, "FleetProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}), close=lambda: None)), \
             patch.object(main, "SyncProvider", return_value=SimpleNamespace(snapshot=lambda session: None, close=lambda: None)), \
             patch.object(main, "resolve_history_settings", return_value=((), {})), \
             patch.object(main, "load_reviewers", return_value=("fixture-reviewer",)), \
             patch.object(main, "AgentsProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}))), \
             patch.object(main, "LiveAgentsProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}))), \
             patch.object(main, "open_browser", return_value=False) as opener, \
             patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(main.main([]), 1)
        nonce = urllib.parse.parse_qs(urllib.parse.urlsplit(opener.call_args.args[0]).fragment)["launch"][0]
        self.assertNotIn(nonce, output.getvalue())
        self.assertNotIn(TOKEN, output.getvalue())
        self.assertIn("Browser opening failed", output.getvalue())

    def test_browser_opener_detaches_and_distinguishes_failure_from_running(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        url = "http://127.0.0.1:1234/bootstrap#launch=fixture-only"
        for exit_code, expected in [(0, True), (7, False), (None, True)]:
            with self.subTest(exit_code=exit_code):
                def wait(timeout):
                    self.assertEqual(timeout, 10)
                    if exit_code is None:
                        raise subprocess.TimeoutExpired("fixture-xdg-open", timeout)
                    return exit_code
                with patch.object(main.sys, "platform", "linux"), \
                     patch.object(main.shutil, "which", return_value="/fixture/xdg-open"), \
                     patch.object(main.subprocess, "Popen", return_value=SimpleNamespace(wait=wait)) as popen:
                    self.assertEqual(main.open_browser(url), expected)
                popen.assert_called_once_with(["/fixture/xdg-open", url], stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        with patch.object(main.shutil, "which", return_value=None):
            self.assertFalse(main.open_browser(url))
        with patch.object(main.shutil, "which", return_value="/fixture/open"), \
             patch.object(main.subprocess, "Popen", side_effect=OSError("fixture-only")):
            self.assertFalse(main.open_browser(url))

    def test_foreground_opener_timeout_keeps_authenticated_server_alive(self):
        main = importlib.import_module("mergepath.cockpit.__main__")
        output = io.StringIO()
        client = GitHubClient(TOKEN, transport=HTTPFixture())
        seen = {"served": False, "joined": False, "nonce": None}
        real_join = threading.Thread.join
        def opener(command, **kwargs):
            url = command[1]
            parts = urllib.parse.urlsplit(url)
            fragment = urllib.parse.parse_qs(parts.fragment)
            authority = "http://" + parts.netloc
            nonce, scope = fragment["launch"][0], fragment["scope"][0]
            seen["nonce"] = nonce
            def wait(timeout):
                port = int(authority.rsplit(":", 1)[1])
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
                connection.request("POST", "/api/bootstrap", headers={"Origin": authority,
                    "X-Cockpit-Bootstrap": nonce, "X-Cockpit-CSRF": nonce})
                response = connection.getresponse()
                self.assertEqual(response.status, 204)
                cookies = [value for name, value in response.getheaders() if name.lower() == "set-cookie"]
                cookie = cookies[-1].split(";", 1)[0]
                response.read()
                connection.request("GET", f"/s/{scope}/api/snapshot", headers={"Cookie": cookie})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read())["schema"], "cockpit/v1")
                connection.close()
                seen["served"] = True
                raise subprocess.TimeoutExpired(command, timeout)
            return SimpleNamespace(wait=wait)
        def interrupt_after_launch(thread, timeout=None):
            if thread.name == "cockpit-http" and not seen["joined"]:
                self.assertTrue(thread.is_alive())
                self.assertTrue(seen["served"])
                seen["joined"] = True
                raise KeyboardInterrupt
            return real_join(thread, timeout)
        with patch.object(main.GitHubClient, "from_environment", return_value=client), \
             patch.object(main, "load_inventory", return_value=(Repository("mergepath", HUB, True),)), \
             patch.object(main, "AuthorBudgetProvider", return_value=author_fixture()), \
             patch.object(main, "FleetProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}), close=lambda: None)), \
             patch.object(main, "SyncProvider", return_value=SimpleNamespace(snapshot=lambda session: None, close=lambda: None)), \
             patch.object(main, "resolve_history_settings", return_value=((), {})), \
             patch.object(main, "load_reviewers", return_value=("fixture-reviewer",)), \
             patch.object(main, "AgentsProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}))), \
             patch.object(main, "LiveAgentsProvider", return_value=SimpleNamespace(fetch=lambda deadline: Sample({}))), \
             patch.object(main.shutil, "which", return_value="/fixture/xdg-open"), \
             patch.object(main.subprocess, "Popen", side_effect=opener), \
             patch.object(threading.Thread, "join", interrupt_after_launch), \
             patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(main.main([]), 0)
        self.assertTrue(seen["served"] and seen["joined"])
        self.assertNotIn("Browser opening failed", output.getvalue())
        self.assertNotIn(seen["nonce"], output.getvalue())
        self.assertNotIn(TOKEN, output.getvalue())


if __name__ == "__main__":
    # Network safety net for the whole fixture process. The real localhost
    # server is exercised, but even an accidental HTTP fallback cannot escape.
    real_connect = socket.create_connection
    def loopback_only(address, *args, **kwargs):
        if address[0] != "127.0.0.1":
            raise AssertionError("remote network forbidden in Cockpit fixtures")
        return real_connect(address, *args, **kwargs)
    with patch("socket.create_connection", loopback_only):
        unittest.main(verbosity=2)
