"""Authenticated loopback HTTP, SSE and fixed server-owned actions."""

import hmac
import json
import math
import mimetypes
import secrets
import socket
import threading
import time
import urllib.parse
from http import HTTPStatus
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .inventory import public_inventory
from .scheduler import Scheduler
from .sync import SyncError


PANEL_IDS = ("prs", "ci", "agents", "history", "fleet", "budget")


SYNC_BODY_SECONDS = 10

COOKIE = "mergepath_cockpit"
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
       "font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; "
       "frame-ancestors 'none'")
EXTENSIONS = {".html", ".js", ".css", ".png", ".svg", ".ico", ".woff2"}


def _secret_equal(supplied, expected):
    return supplied.isascii() and hmac.compare_digest(supplied, expected)


class Application:
    def __init__(self, inventory, github, *, static_root=None, heartbeat=15,
                 clock=time.time, monotonic=time.monotonic, logger=lambda message: None):
        if heartbeat <= 0:
            raise ValueError("invalid_heartbeat")
        self.inventory, self.github = inventory, github
        self.static_root = Path(static_root or Path(__file__).parent)
        self.heartbeat, self.clock, self.monotonic, self.logger = heartbeat, clock, monotonic, logger
        self._nonce, self._session, self._csrf = (secrets.token_urlsafe(32) for _ in range(3))
        self._scope = secrets.token_urlsafe(32)
        self._nonce_expires, self._nonce_used = monotonic() + 120, False
        self._revision = 0
        self._panel_sources = {}
        self.sync = None
        self.ci_excerpts = None
        self._condition = threading.Condition()
        self.stopping = threading.Event()
        self.stream_slots = threading.BoundedSemaphore(2)
        self.scheduler = Scheduler(changed=self.publish, clock=clock, monotonic=monotonic)

    def launch_url(self, port):
        return f"http://127.0.0.1:{port}/bootstrap#launch={self._nonce}&scope={self._scope}"

    @property
    def scope_path(self):
        return f"/s/{self._scope}/"

    def bootstrap(self, nonce, csrf):
        with self._condition:
            if (self._nonce_used or self.monotonic() >= self._nonce_expires
                    or not _secret_equal(nonce, self._nonce)
                    or not _secret_equal(csrf, self._nonce)):
                return False
            self._nonce_used = True
            return True

    def publish(self):
        with self._condition:
            self._revision += 1
            self._condition.notify_all()

    def redact(self, value):
        if isinstance(value, str):
            for secret in (self._nonce, self._session, self._csrf, self._scope, self.github._token):
                value = value.replace(secret, "[redacted]")
            return value
        if isinstance(value, dict):
            return {self.redact(key): self.redact(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.redact(item) for item in value]
        return value

    def snapshot(self, repo=None):
        with self._condition:
            revision = self._revision
        return {"schema": "cockpit/v1", "revision": revision,
                "generated_at": self.clock(), "repositories": public_inventory(self.inventory, repo),
                "api_budget": self.github.budget(), "sources": self.redact(self.scheduler.snapshot()),
                "sync": self.redact(self.sync.snapshot(self._session)) if self.sync else None}

    def register_panel(self, panel, source):
        """Bind a fixed panel once to an existing server-owned source."""
        with self._condition:
            if (panel not in PANEL_IDS or not isinstance(source, str)
                    or source not in self.scheduler.snapshot()):
                raise ValueError("invalid_panel_source")
            if panel in self._panel_sources:
                raise ValueError("duplicate_panel")
            self._panel_sources[panel] = source

    def panel_snapshot(self, panel):
        if panel not in PANEL_IDS:
            raise ValueError("invalid_panel")
        with self._condition:
            source = self._panel_sources.get(panel)
        snapshot = self.snapshot()
        envelope = snapshot["sources"].get(source) if source else None
        if envelope is None:
            envelope = {"data": None, "observed_at": None, "attempted_at": None,
                        "stale": True, "error": "unavailable", "retry_at": None,
                        "in_flight": False}
        return {"schema": "cockpit-panel/v1", "panel": panel,
                "source": source, "envelope": envelope}

    def refresh_fleet(self):
        """Refresh only the launch-bound audit source; never accept a command."""
        with self._condition:
            source = self._panel_sources.get("fleet")
        if source is None or self.stopping.is_set():
            raise ValueError("fleet_unavailable")
        self.scheduler.refresh(source)

    def sync_action(self, action, payload):
        """Dispatch only named operations against the launch-owned provider."""
        if self.sync is None or self.stopping.is_set():
            raise SyncError("sync_unavailable")
        if action not in ("preview", "confirm", "cancel") or type(payload) is not dict:
            raise SyncError("invalid_request")
        return self.redact(getattr(self.sync, action)(self._session, payload))

    def close(self):
        self.stopping.set()
        try:
            if self.sync is not None:
                self.sync.close()
        finally:
            self.scheduler.close()
            self.publish()


class CockpitServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, app, port=0):
        if not isinstance(port, int) or not 0 <= port <= 65535:
            raise ValueError("invalid_port")
        self.app = app
        self._request_slots = threading.BoundedSemaphore(8)
        super().__init__(("127.0.0.1", port), Handler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(10)
        return request, address

    def process_request(self, request, client_address):
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._request_slots.release()
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()

    def handle_error(self, request, client_address):
        self.app.logger("request failed")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MergepathCockpit"
    sys_version = ""

    # Route unknown methods through the same auth/CSRF boundary, not the base
    # handler's unauthenticated 501 response or raw method/path error message.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self._handle
        raise AttributeError(name)

    def log_message(self, format, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self._respond(code, {"error": "invalid_request"})

    def _respond(self, status, payload=None, *, raw=None, content_type="application/json", cookie=None):
        data = raw if raw is not None else json.dumps(payload, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self._headers()
        self.send_header("Connection", "close")
        if cookie:
            for value in cookie if isinstance(cookie, tuple) else (cookie,):
                self.send_header("Set-Cookie", value)
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(data)
        self.server.app.logger(f"request status={int(status)}")

    def _headers(self):
        for key, value in (("Content-Security-Policy", CSP), ("X-Content-Type-Options", "nosniff"),
                           ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store")):
            self.send_header(key, value)

    def _single(self, name):
        values = self.headers.get_all(name, [])
        return values[0] if len(values) == 1 else ""

    def _session_valid(self):
        value = self._single("Cookie")
        # SimpleCookie accepts duplicate names by keeping the last value;
        # refuse that ambiguity before parsing anything.
        if sum(part.strip().startswith(COOKIE + "=") for part in value.split(";")) != 1:
            return False
        try:
            cookie = SimpleCookie()
            cookie.load(value)
            supplied = cookie[COOKIE].value if COOKIE in cookie else ""
            return _secret_equal(supplied, self.server.app._session)
        except (CookieError, TypeError):
            return False

    def _handle(self):
        app = self.server.app
        host = self._single("Host")
        port = self.server.server_address[1]
        if host not in {f"127.0.0.1:{port}", f"localhost:{port}"}:
            self._respond(403, {"error": "host_refused"})
            return
        origin = self._single("Origin")
        if self.headers.get_all("Origin") and origin != "http://" + host:
            self._respond(403, {"error": "origin_refused"})
            return
        if self._single("Sec-Fetch-Site") in {"cross-site", "same-site"}:
            self._respond(403, {"error": "origin_refused"})
            return
        try:
            parts = urllib.parse.urlsplit(self.path)
        except ValueError:
            self._respond(400, {"error": "invalid_request"})
            return
        if (parts.scheme or parts.netloc or parts.fragment or not self.path.startswith("/")
                or self.path.startswith("//") or any(ord(c) < 32 for c in self.path)):
            self._respond(400, {"error": "invalid_request"})
            return
        if self.headers.get_all("Transfer-Encoding"):
            self._respond(400, {"error": "invalid_framing"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if lengths and (len(lengths) != 1 or len(lengths[0]) > 10
                        or not lengths[0].isascii() or not lengths[0].isdigit()):
            self._respond(400, {"error": "invalid_framing"})
            return
        length = int(lengths[0]) if lengths else 0
        if length > 4096:
            self._respond(413, {"error": "body_too_large"})
            return
        public = self.command == "GET" and parts.path in {"/bootstrap", "/bootstrap.js"} and not parts.query
        bootstrap = self.command == "POST" and parts.path == "/api/bootstrap" and not parts.query
        if bootstrap:
            if (origin != "http://" + host or length or not app.bootstrap(
                    self._single("X-Cockpit-Bootstrap"), self._single("X-Cockpit-CSRF"))):
                self._respond(403, {"error": "bootstrap_refused"})
                return
            # Remove only an old host-wide cookie. Otherwise browsers send it
            # alongside the scoped cookie and duplicate-name checks refuse it.
            self._respond(204, raw=b"", cookie=(
                f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict",
                f"{COOKIE}={app._session}; Path={app.scope_path}; HttpOnly; SameSite=Strict"))
            return
        if not public:
            # Cookie hosts ignore ports. The independent unguessable scope is
            # required before every protected route and never disclosed here.
            if not parts.path.startswith(app.scope_path):
                self._respond(404, {"error": "not_found"})
                return
            parts = parts._replace(path="/" + parts.path[len(app.scope_path):])
        if not public and not self._session_valid():
            self._respond(401, {"error": "session_required"})
            return
        if self.command != "GET":
            if (origin != "http://" + host or not _secret_equal(
                    self._single("X-Cockpit-CSRF"), app._csrf)):
                self._respond(403, {"error": "csrf_refused"})
            elif self.command == "POST" and parts.path in {
                    "/api/sync/preview", "/api/sync/confirm", "/api/sync/cancel"}:
                if parts.query or not length or self._single("Content-Type") != "application/json":
                    self._respond(400, {"error": "invalid_request"})
                    return
                def expire_body():
                    try:
                        self.connection.shutdown(socket.SHUT_RD)
                    except OSError:
                        pass
                body_timer = threading.Timer(SYNC_BODY_SECONDS, expire_body)
                body_timer.daemon = True
                body_timer.start()
                try:
                    raw = self.rfile.read(length)
                    if len(raw) != length:
                        raise ValueError("short_body")
                    def unique_object(pairs):
                        result = {}
                        for key, value in pairs:
                            if key in result:
                                raise ValueError("duplicate_key")
                            result[key] = value
                        return result
                    def refuse_constant(value):
                        raise ValueError("invalid_number")
                    def finite_float(value):
                        result = float(value)
                        if not math.isfinite(result):
                            raise ValueError("invalid_number")
                        return result
                    payload = json.loads(raw, object_pairs_hook=unique_object,
                                         parse_constant=refuse_constant, parse_float=finite_float)
                    if type(payload) is not dict:
                        raise ValueError("invalid_object")
                except (ValueError, UnicodeError, OSError, RecursionError):
                    self._respond(400, {"error": "invalid_request"})
                    return
                finally:
                    body_timer.cancel()
                try:
                    result = app.sync_action(parts.path.rsplit("/", 1)[1], payload)
                except SyncError as error:
                    reason = str(error)
                    self._respond(503 if reason == "sync_unavailable" else 409, {"error": reason})
                else:
                    self._respond(202, result)
            elif self.command == "POST" and parts.path == "/api/fleet/refresh":
                if parts.query or length:
                    self._respond(400, {"error": "invalid_refresh"})
                    return
                try:
                    app.refresh_fleet()
                except ValueError:
                    self._respond(503, {"error": "fleet_unavailable"})
                else:
                    self._respond(202, {"accepted": True})
            else:
                self._respond(405, {"error": "method_not_allowed"})
            return
        if public:
            suffix = "bootstrap.html" if parts.path == "/bootstrap" else "bootstrap.js"
            data = (Path(__file__).parent / suffix).read_bytes()
            self._respond(200, raw=data, content_type="text/html; charset=utf-8" if suffix.endswith("html")
                          else "text/javascript; charset=utf-8")
        elif parts.path == "/api/session" and not parts.query:
            self._respond(200, {"csrf": app._csrf})
        elif parts.path == "/api/snapshot":
            query = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
            if set(query) - {"repo"} or any(len(value) != 1 for value in query.values()):
                self._respond(400, {"error": "invalid_filter"})
                return
            try:
                self._respond(200, app.snapshot(query.get("repo", [None])[0]))
            except ValueError:
                self._respond(400, {"error": "invalid_filter"})
        elif parts.path == "/api/ci/excerpt":
            query = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
            if set(query) != {"repo", "run", "attempt", "job", "step"} or any(len(values) != 1 for values in query.values()):
                self._respond(400, {"error": "invalid_excerpt_request"})
            elif app.ci_excerpts is None:
                self._respond(503, {"error": "upstream_unavailable"})
            else:
                try:
                    result = app.ci_excerpts.handle({key: values[0] for key, values in query.items()},
                        app.panel_snapshot("ci")["envelope"], deadline=app.monotonic() + 15)
                    self._respond(200, app.redact(result))
                except ValueError:
                    self._respond(400, {"error": "invalid_excerpt_request"})
                except Exception:
                    self._respond(503, {"error": "upstream_unavailable"})
        elif parts.path.startswith("/api/panels/"):
            panel = parts.path[len("/api/panels/"):]
            if panel not in PANEL_IDS:
                self._respond(404, {"error": "not_found"})
            elif parts.query:
                self._respond(400, {"error": "invalid_panel_query"})
            else:
                self._respond(200, app.panel_snapshot(panel))
        elif parts.path == "/events" and not parts.query:
            self._events()
        elif not parts.query:
            self._static(parts.path)
        else:
            self._respond(404, {"error": "not_found"})

    def _static(self, path):
        root = self.server.app.static_root.resolve()
        decoded = urllib.parse.unquote(path)
        if decoded == "/":
            candidate = root / "index.html"
        elif decoded.startswith("/assets/"):
            segments = decoded[len("/assets/"):].split("/")
            if any(part in {"", ".", ".."} for part in segments) or "\\" in decoded or "%" in decoded:
                self._respond(404, {"error": "not_found"})
                return
            candidate = root / "assets" / Path(*segments)
        else:
            self._respond(404, {"error": "not_found"})
            return
        try:
            resolved = candidate.resolve(strict=True)
            if not resolved.is_relative_to(root) or resolved.suffix.lower() not in EXTENSIONS or not resolved.is_file():
                raise OSError()
            data = resolved.read_bytes()
        except (OSError, ValueError):
            self._respond(503 if decoded == "/" else 404,
                          {"error": "visual_shell_unavailable" if decoded == "/" else "not_found"})
            return
        mime = mimetypes.guess_type(str(resolved))[0] or "application/octet-stream"
        self._respond(200, raw=data, content_type=mime)

    def _events(self):
        app = self.server.app
        if not app.stream_slots.acquire(blocking=False):
            self._respond(503, {"error": "stream_capacity"})
            return
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self._headers()
            self.end_headers()
            self.close_connection = True
            self.wfile.write(b"retry: 2000\n\n")
            self.wfile.flush()
            app.logger("request status=200")
            revision = -1
            while not app.stopping.is_set():
                snapshot = app.snapshot()
                if snapshot["revision"] != revision:
                    revision = snapshot["revision"]
                    data = json.dumps(snapshot, allow_nan=False, separators=(",", ":"))
                    self.wfile.write(f"id: {revision}\nevent: snapshot\ndata: {data}\n\n".encode())
                    self.wfile.flush()
                with app._condition:
                    updated = app._condition.wait_for(
                        lambda: app.stopping.is_set() or app._revision != revision, timeout=app.heartbeat)
                if not updated:
                    self.wfile.write(b"event: heartbeat\ndata: {}\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass
        finally:
            app.stream_slots.release()
