"""Bounded, response-header-accounted, read-only GitHub transport."""

import copy
import contextlib
import http.client
import json
import re
import socket
import threading
import time
import urllib.parse
from collections import OrderedDict
from dataclasses import dataclass
from email.utils import parsedate_to_datetime


ORIGIN = "https://api.github.com"
MAX_BODY = 2 * 1024 * 1024


class ClientError(Exception):
    """Stable errors only: never expose an upstream body, path or credential."""

    def __init__(self, category, retry_after=0, response=None):
        super().__init__(category)
        self.category = category
        self.retry_after = max(0, retry_after)
        self.response = response


@dataclass(frozen=True)
class Response:
    status: int
    headers: dict
    body: bytes


def http_transport(method, url, headers, body, timeout):
    # Direct HTTPS ignores ambient proxies and does not follow redirects.
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.netloc != "api.github.com" or parts.fragment:
        raise ClientError("invalid_endpoint")
    deadline = time.monotonic() + timeout
    connection = http.client.HTTPSConnection("api.github.com", timeout=timeout)
    active_socket = None
    reply = None

    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise ClientError("deadline_exceeded")
        return value

    def abort():
        # A read1 timeout is an idle timeout. Shutdown at the absolute deadline
        # also interrupts a body trickling indefinitely below that idle bound.
        if active_socket is not None:
            with contextlib.suppress(OSError):
                active_socket.shutdown(socket.SHUT_RDWR)

    timer = threading.Timer(timeout, abort)
    timer.daemon = True
    timer.start()
    try:
        connection.connect()
        active_socket = connection.sock
        active_socket.settimeout(remaining())
        path = parts.path + ("?" + parts.query if parts.query else "")
        connection.request(method, path, body=body, headers=headers)
        active_socket.settimeout(remaining())
        reply = connection.getresponse()
        chunks, size = [], 0
        while size <= MAX_BODY:
            active_socket.settimeout(remaining())
            chunk = reply.read1(min(65536, MAX_BODY + 1 - size))
            remaining()
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return Response(reply.status, dict(reply.getheaders()), b"".join(chunks))
    except ClientError as exc:
        if reply is not None:
            exc.response = Response(reply.status, dict(reply.getheaders()), b"")
        raise
    except (OSError, http.client.HTTPException):
        category = "deadline_exceeded" if time.monotonic() >= deadline else "upstream_unavailable"
        metadata = Response(reply.status, dict(reply.getheaders()), b"") if reply is not None else None
        raise ClientError(category, response=metadata) from None
    finally:
        timer.cancel()
        connection.close()


def _integer(value):
    return int(value) if isinstance(value, str) and re.fullmatch(r"[0-9]{1,15}", value) else None


def _retry_delay(value, now):
    number = _integer(value)
    if number is not None:
        return number
    if value:
        try:
            return max(0, parsedate_to_datetime(value).timestamp() - now)
        except (TypeError, ValueError, OverflowError):
            pass
    return 0


def _next_link(link):
    if not link:
        return None
    next_links = []
    # GitHub emits RFC-style angle-bracket URLs and rel parameters. Refuse
    # malformed entries rather than mistaking an unreadable next link for EOF.
    for entry in re.split(r",(?=\s*<)", link):
        match = re.fullmatch(r'\s*<([^<>\s]+)>((?:\s*;\s*[A-Za-z][A-Za-z0-9_-]*=(?:"[^"\r\n]*"|[^\s;,]+))*)\s*', entry)
        if not match:
            raise ClientError("invalid_next_link")
        parameters = re.findall(r';\s*([A-Za-z][A-Za-z0-9_-]*)=("[^"\r\n]*"|[^\s;,]+)', match[2])
        relations = [value.strip('"').split() for key, value in parameters if key.lower() == "rel"]
        if len(relations) > 1:
            raise ClientError("invalid_next_link")
        if relations and "next" in relations[0]:
            next_links.append(match[1])
    if len(next_links) > 1:
        raise ClientError("invalid_next_link")
    return next_links[0] if next_links else None


def _graphql_secondary(body):
    """Only GraphQL error messages can establish an HTTP-200 throttle."""
    if len(body) > MAX_BODY:
        return False
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeError):
        return False
    errors = payload.get("errors") if isinstance(payload, dict) else None
    return isinstance(errors, list) and any(
        isinstance(error, dict) and isinstance(error.get("message"), str)
        and any(marker in error["message"].lower() for marker in ("secondary rate limit", "abuse detection"))
        for error in errors)


def _query_only(document):
    """Lex strings/comments out before rejecting all non-query operations.

    The server owns documents; callers do not submit arbitrary GraphQL. This
    guard still handles normal/block strings and comments, so text in a query
    cannot mask a second mutation operation or impersonate an operation.
    """
    if not isinstance(document, str) or len(document) > 128 * 1024:
        raise ClientError("invalid_query")
    tokens, index = [], 0
    while index < len(document):
        char = document[index]
        if char.isspace() or char == ",":
            index += 1
        elif char == "#":
            end = document.find("\n", index)
            index = len(document) if end < 0 else end + 1
        elif document.startswith('"""', index):
            index += 3
            while index < len(document):
                if document.startswith('\\"""', index):
                    index += 4
                elif document.startswith('"""', index):
                    index += 3
                    break
                else:
                    index += 1
            else:
                raise ClientError("invalid_query")
        elif char == '"':
            index += 1
            while index < len(document):
                if document[index] == "\\":
                    index += 2
                elif document[index] == '"':
                    index += 1
                    break
                elif document[index] in "\r\n":
                    raise ClientError("invalid_query")
                else:
                    index += 1
            else:
                raise ClientError("invalid_query")
        elif char.isalpha() or char == "_":
            end = index + 1
            while end < len(document) and (document[end].isalnum() or document[end] == "_"):
                end += 1
            tokens.append(document[index:end])
            index = end
        else:
            tokens.append(char)
            index += 1
    if not tokens or tokens[0] not in {"query", "{"}:
        raise ClientError("query_only")
    # Track selection-set nesting: operation keywords at root are never reads.
    depth, operations = 0, 0
    for token in tokens:
        if token == "{":
            if depth == 0:
                operations += 1
            depth += 1
        elif token == "}":
            depth -= 1
            if depth < 0:
                raise ClientError("invalid_query")
        elif depth == 0 and token in {"mutation", "subscription"}:
            raise ClientError("query_only")
    # One query selection set, no fragments/other operations in this small seam.
    # A single document can contain arbitrarily many aliases for batching.
    if depth or operations != 1 or "fragment" in tokens:
        raise ClientError("invalid_query")


class GitHubClient:
    def __init__(self, token, *, transport=http_transport, clock=time.time,
                 monotonic=time.monotonic, reserve=100, cache_pages=256,
                 configured_identity=None):
        if not isinstance(token, str) or not token or any(c.isspace() for c in token):
            raise ClientError("cached_reviewer_credential_required")
        if reserve < 0 or cache_pages < 1:
            raise ValueError("invalid_client_bounds")
        self._token, self._transport = token, transport
        self._configured_identity = configured_identity
        self._clock, self._monotonic = clock, monotonic
        self._reserve, self._cache_pages = reserve, cache_pages
        self._cache = OrderedDict()
        self._endpoint_resources = OrderedDict()
        self._budgets = {}
        self._throttle_until = 0
        self._lock = threading.RLock()
        self._transport_lock = threading.Lock()

    @classmethod
    def from_environment(cls, env, **kwargs):
        # No GH_TOKEN, author-PAT or keyring fallback.
        agent = env.get("OP_PREFLIGHT_AGENT")
        identity = "nathanpayne-" + agent if agent in {"codex", "claude", "cursor"} else None
        return cls(env.get("OP_PREFLIGHT_REVIEWER_PAT"), configured_identity=identity, **kwargs)

    def budget(self):
        with self._lock:
            return copy.deepcopy(self._budgets)

    @contextlib.contextmanager
    def _serialized(self, deadline):
        remaining = deadline - self._monotonic()
        if remaining <= 0 or not self._transport_lock.acquire(timeout=remaining):
            raise ClientError("deadline_exceeded")
        try:
            yield
        finally:
            self._transport_lock.release()

    def _resource(self, path):
        endpoint = urllib.parse.urlsplit(path).path
        with self._lock:
            learned = self._endpoint_resources.get(endpoint)
        if learned:
            return learned
        if endpoint == "/search/code":
            return "code_search"
        return "search" if endpoint.startswith("/search/") else "core"

    def _path(self, path):
        if not isinstance(path, str) or len(path) > 8192 or any(ord(c) < 33 for c in path):
            raise ClientError("invalid_endpoint")
        parts = urllib.parse.urlsplit(path)
        decoded = urllib.parse.unquote(parts.path)
        if (parts.scheme or parts.netloc or parts.fragment or not parts.path.startswith("/")
                or parts.path.startswith("//") or "\\" in decoded
                or any(part in {".", ".."} for part in decoded.split("/"))
                or decoded == "/rate_limit" or not decoded.startswith(("/repos/", "/users/", "/orgs/", "/search/"))):
            raise ClientError("invalid_endpoint")
        return path

    def _request(self, path, resource, *, document=None, deadline=None):
        # One lock serializes transports across sources and enforces global
        # backoff even when several sources were due at the same instant.
        deadline = self._monotonic() + 15 if deadline is None else deadline
        with self._serialized(deadline):
            # Re-select after the transport fence: an earlier caller/page may
            # have learned the endpoint's actual pool while this one waited.
            if document is None:
                resource = self._resource(path)
            now = self._clock()
            if self._throttle_until > now:
                raise ClientError("upstream_backoff", self._throttle_until - now)
            with self._lock:
                budget = self._budgets.get(resource, {}).copy()
            remaining, reset, limit = budget.get("remaining"), budget.get("reset"), budget.get("limit")
            reserve = min(self._reserve, limit // 50) if limit and limit > 0 else 0
            if remaining is not None and reset and reset > now:
                if remaining == 0:
                    raise ClientError("primary_exhausted", reset - now)
                if remaining <= reserve:
                    raise ClientError("primary_reserve", reset - now)
            available = min(15, deadline - self._monotonic())
            if available <= 0:
                raise ClientError("deadline_exceeded")
            headers = {"Authorization": "Bearer " + self._token,
                       "Accept": "application/vnd.github+json",
                       "X-GitHub-Api-Version": "2022-11-28",
                       "User-Agent": "mergepath-cockpit"}
            cached = self._cache.get(path) if document is None else None
            if cached and cached[1]:
                headers["If-None-Match"] = cached[1]
            body = None
            if document is not None:
                body = json.dumps(document, allow_nan=False).encode()
                headers["Content-Type"] = "application/json"
            transport_error = None
            try:
                reply = self._transport("GET" if document is None else "POST",
                                        ORIGIN + path, headers, body, available)
            except ClientError as exc:
                if exc.response is None:
                    raise
                reply, transport_error = exc.response, exc.category
            except Exception:
                raise ClientError("upstream_unavailable") from None
            lower = {key.lower(): str(value) for key, value in reply.headers.items()}
            observed = self._clock()
            label = lower.get("x-ratelimit-resource", resource)
            if not re.fullmatch(r"[a-z_]{1,40}", label):
                label = resource
            evidence = {name: _integer(lower.get("x-ratelimit-" + name))
                        for name in ("limit", "remaining", "used", "reset")}
            evidence.update(observed_at=observed, status=reply.status,
                            retry_after=_retry_delay(lower.get("retry-after"), observed),
                            resource=label, credential_source="OP_PREFLIGHT_REVIEWER_PAT",
                            configured_identity=self._configured_identity,
                            identity_evidence="preflight_configured" if self._configured_identity else "unknown")
            primary = evidence["remaining"] == 0 and evidence["reset"] is not None and evidence["reset"] > observed
            secondary = reply.status == 429 or (reply.status == 403 and (
                evidence["retry_after"] > 0 or any(marker in reply.body.lower() for marker in
                (b"secondary rate limit", b"abuse detection")))) or (
                document is not None and reply.status == 200 and _graphql_secondary(reply.body))
            evidence["primary_exhausted"] = primary
            evidence["secondary_limited"] = secondary
            with self._lock:
                self._budgets[label] = evidence
                if document is None:
                    endpoint = urllib.parse.urlsplit(path).path
                    self._endpoint_resources[endpoint] = label
                    self._endpoint_resources.move_to_end(endpoint)
                    while len(self._endpoint_resources) > self._cache_pages:
                        self._endpoint_resources.popitem(last=False)
            if secondary:
                delay = max(60, evidence["retry_after"])
                self._throttle_until = observed + delay
                raise ClientError("secondary_limit", delay)
            if reply.status == 403 and primary:
                raise ClientError("primary_exhausted", evidence["reset"] - observed)
            if transport_error:
                raise ClientError(transport_error)
            if self._monotonic() >= deadline:
                raise ClientError("deadline_exceeded")
            if len(reply.body) > MAX_BODY:
                raise ClientError("response_too_large")
            if reply.status == 304:
                if cached is None:
                    raise ClientError("uncached_not_modified")
                payload, etag, link = cached
                link = lower.get("link", link)
            elif reply.status == 200:
                try:
                    payload = json.loads(reply.body)
                except (ValueError, UnicodeError):
                    raise ClientError("invalid_upstream_json") from None
                etag, link = lower.get("etag"), lower.get("link", "")
            else:
                raise ClientError("permission_denied" if reply.status in {401, 403} else "upstream_http_error")
            if document is None:
                self._cache[path] = (payload, etag, link)
                self._cache.move_to_end(path)
                while len(self._cache) > self._cache_pages:
                    self._cache.popitem(last=False)
            return copy.deepcopy(payload), link

    def get(self, path, *, deadline=None):
        path = self._path(path)
        return self._request(path, self._resource(path), deadline=deadline)[0]

    def pages(self, path, *, collection=None, max_pages=10, deadline=None):
        if not 1 <= max_pages <= 100:
            raise ValueError("invalid_page_bound")
        path = self._path(path)
        endpoint, seen, rows = urllib.parse.urlsplit(path).path, set(), []
        deadline = self._monotonic() + 30 if deadline is None else deadline
        for _ in range(max_pages):
            if path in seen:
                raise ClientError("pagination_cycle")
            seen.add(path)
            payload, link = self._request(path, self._resource(path), deadline=deadline)
            page = payload.get(collection) if collection and isinstance(payload, dict) else payload
            if not isinstance(page, list):
                raise ClientError("invalid_page")
            rows.extend(page)
            next_link = _next_link(link)
            if next_link is None:
                return rows
            parts = urllib.parse.urlsplit(next_link)
            if (parts.scheme != "https" or parts.netloc != "api.github.com"
                    or parts.path != endpoint or parts.fragment):
                raise ClientError("invalid_next_link")
            path = self._path(parts.path + ("?" + parts.query if parts.query else ""))
        raise ClientError("page_limit")

    def query(self, document, variables=None, *, deadline=None):
        _query_only(document)
        try:
            payload, _ = self._request("/graphql", "graphql", document={
                "query": document, "variables": variables or {}}, deadline=deadline)
        except (TypeError, ValueError):
            raise ClientError("invalid_query_variables") from None
        if not isinstance(payload, dict) or payload.get("errors") or not isinstance(payload.get("data"), dict):
            raise ClientError("incomplete_graphql")
        return payload["data"]

    @staticmethod
    def next_cursor(connection):
        if not isinstance(connection, dict) or not isinstance(connection.get("pageInfo"), dict):
            raise ClientError("incomplete_graphql_connection")
        info = connection["pageInfo"]
        if not isinstance(info.get("hasNextPage"), bool):
            raise ClientError("incomplete_graphql_connection")
        if not info["hasNextPage"]:
            return None
        cursor = info.get("endCursor")
        if not isinstance(cursor, str) or not cursor:
            raise ClientError("incomplete_graphql_connection")
        return cursor
