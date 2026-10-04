"""Fixed read-only author allowance worker and credential-free scheduler owner."""

import argparse
import copy
from datetime import datetime
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from mergepath.cockpit.github import ClientError, ERROR_CATEGORIES, GitHubClient
from mergepath.cockpit.scheduler import Sample
from mergepath.cockpit.sync import SyncError
from mergepath.cockpit.sync_worker import Runner, cached_author

AUTHOR = "nathanjohnpayne"
QUERY = "{viewer{login} rateLimit{limit remaining used resetAt}}"
SCHEMA = "author-api-budget/v1"
SECONDS = 20
MAX_PUBLIC = 8192
ERRORS = ERROR_CATEGORIES | {"cached_author_required", "author_identity_mismatch", "worker_protocol_error"}
PROVENANCE = {"preflight_configured", "viewer_verified", "last_viewer_verified"}
FIELDS = {"limit", "remaining", "used", "reset", "observed_at", "status", "retry_after",
          "primary_exhausted", "secondary_limited", "resource", "credential_source",
          "configured_identity", "identity_evidence"}


def empty_sample(error=None):
    return {"schema": SCHEMA, "configured_identity": AUTHOR, "verified_identity": None,
            "identity_evidence": "preflight_configured", "budgets": {}, "error": error,
            "stale": error is not None, "retry_at": None}


def number(value):
    return type(value) in (int, float) and 0 <= value <= 10**15 and math.isfinite(value)


def public_sample(value):
    """Reject all unrecognized child fields; never forward opaque diagnostics."""
    if (type(value) is not dict or set(value) != set(empty_sample()) or value["schema"] != SCHEMA
            or value["configured_identity"] != AUTHOR or value["verified_identity"] not in (None, AUTHOR)
            or value["identity_evidence"] not in PROVENANCE or type(value["stale"]) is not bool
            or value["error"] is not None and value["error"] not in ERRORS
            or value["retry_at"] is not None and not number(value["retry_at"])
            or type(value["budgets"]) is not dict or set(value["budgets"]) - {"graphql"}):
        raise ValueError("worker_protocol_error")
    for pool, row in value["budgets"].items():
        if (type(row) is not dict or set(row) != FIELDS or row["resource"] != pool
                or row["credential_source"] != "OP_PREFLIGHT_AUTHOR_PAT"
                or row["configured_identity"] != AUTHOR or row["identity_evidence"] not in PROVENANCE
                or any(row[key] is not None and (type(row[key]) is not int or not number(row[key]))
                       for key in ("limit", "remaining", "used", "reset", "status"))
                or not number(row["observed_at"]) or not number(row["retry_after"])
                or any(type(row[key]) is not bool for key in ("primary_exhausted", "secondary_limited"))):
            raise ValueError("worker_protocol_error")
    return copy.deepcopy(value)


def measure(root, cache_dir, agent, env, deadline, *, client_factory=GitHubClient,
            runner_factory=Runner, clock=time.time):
    """This function runs only in the private child; one query, no retries."""
    result = empty_sample()
    try:
        code, exports = runner_factory(min(deadline, time.monotonic() + 10)).run(
            ["/bin/bash", str(root / "scripts/op-preflight.sh"), "--agent", agent,
             "--mode", "review", "--check", "--print-exports"], root, env, limit=65536)
        if code != 0:
            raise SyncError("cached_author_required")
        token = cached_author(exports)
        exports = b""
        client = client_factory(token, reserve=0, configured_identity=AUTHOR)
        error, data = None, None
        try:
            data = client.query(QUERY, deadline=deadline)
        except ClientError as exc:
            error = exc.category
        evidence = client.budget().get("graphql")
        if data is not None:
            if type(data.get("viewer")) is not dict or data["viewer"].get("login") != AUTHOR:
                return empty_sample("author_identity_mismatch")
            result.update(verified_identity=AUTHOR, identity_evidence="viewer_verified")
            rate = data.get("rateLimit")
            if (type(rate) is not dict or any(type(rate.get(k)) is not int or not number(rate[k])
                                             for k in ("limit", "remaining", "used"))
                    or rate["remaining"] > rate["limit"] or rate["used"] > rate["limit"]
                    or type(rate.get("resetAt")) is not str or len(rate["resetAt"]) > 32):
                error = "invalid_upstream_json"
            else:
                try:
                    reset = datetime.fromisoformat(rate["resetAt"].replace("Z", "+00:00"))
                    if reset.tzinfo is None:
                        raise ValueError()
                    body = {k: rate[k] for k in ("limit", "remaining", "used")}
                    body["reset"] = int(reset.timestamp())
                    if evidence is not None:
                        for key, value in body.items():
                            if evidence.get(key) is None:
                                evidence[key] = value
                except (ValueError, OverflowError):
                    error = "invalid_upstream_json"
        if evidence is not None:
            row = {key: evidence.get(key) for key in FIELDS}
            row.update(resource="graphql", credential_source="OP_PREFLIGHT_AUTHOR_PAT",
                       configured_identity=AUTHOR, identity_evidence=result["identity_evidence"])
            row["primary_exhausted"] = row["remaining"] == 0 and row["reset"] is not None and row["reset"] > clock()
            result["budgets"] = {"graphql": row}
            if row["primary_exhausted"]:
                error = "primary_exhausted"
        result.update(error=error, stale=error is not None)
        return public_sample(result)
    except SyncError:
        return empty_sample("cached_author_required")
    except Exception:
        return empty_sample("source_failed")


class AuthorBudgetProvider:
    def __init__(self, root, cache_dir, agent, *, clock=time.time, monotonic=time.monotonic):
        if agent not in ("codex", "claude", "cursor"):
            raise ValueError("invalid_agent")
        self.root, self.cache_dir, self.agent = Path(root).resolve(), str(cache_dir), agent
        self.clock, self.monotonic = clock, monotonic
        self._last, self._blocked, self._failures = empty_sample("unavailable"), 0, 0
        self._process, self._closed = None, False
        self._lock = threading.RLock()
        self.workspace = None
        try:
            self.workspace = Path(tempfile.mkdtemp(prefix="cockpit-author-api-"))
            self.workspace.chmod(0o700)
            for name in ("home", "config", "cache", "tmp"):
                (self.workspace / name).mkdir(mode=0o700)
        except OSError:
            if self.workspace is not None:
                shutil.rmtree(self.workspace, ignore_errors=True)
            self.workspace = None

    def _environment(self):
        return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.workspace / "home"),
                "XDG_CONFIG_HOME": str(self.workspace / "config"), "XDG_CACHE_HOME": str(self.workspace / "cache"),
                "TMPDIR": str(self.workspace / "tmp"), "LC_ALL": "C", "OP_PREFLIGHT_QUIET": "1",
                "OP_PREFLIGHT_CACHE_DIR": self.cache_dir}

    @staticmethod
    def _kill(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)

    def _read(self, deadline):
        command = [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--worker",
                   "--root", str(self.root), "--cache-dir", self.cache_dir, "--agent", self.agent,
                   "--deadline", str(deadline)]
        with self._lock:
            if self._closed:
                return empty_sample("source_failed")
            process = subprocess.Popen(command, cwd=self.root, env=self._environment(), stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            self._process = process
        output, size = bytearray(), 0
        try:
            with selectors.DefaultSelector() as selector:
                for pipe in (process.stdout, process.stderr):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ)
                while selector.get_map():
                    if self.monotonic() >= deadline:
                        raise TimeoutError()
                    for key, _ in selector.select(min(.05, max(0, deadline - self.monotonic()))):
                        chunk = os.read(key.fd, MAX_PUBLIC + 1)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        size += len(chunk)
                        if size > MAX_PUBLIC:
                            raise ValueError()
                        if key.fileobj is process.stdout:
                            output.extend(chunk)
            if process.wait(timeout=max(.001, deadline - self.monotonic())) != 0:
                raise ValueError()
            return public_sample(json.loads(output))
        except (TimeoutError, subprocess.TimeoutExpired):
            return empty_sample("deadline_exceeded")
        except (OSError, ValueError, TypeError, RecursionError, UnicodeError):
            return empty_sample("worker_protocol_error")
        finally:
            try:
                self._kill(process)
            finally:
                process.stdout.close()
                process.stderr.close()
                with self._lock:
                    self._process = None

    def fetch(self, deadline):
        with self._lock:
            if self.workspace is None:
                return Sample(empty_sample("upstream_unavailable"))
            if self._closed or self.clock() < self._blocked:
                return Sample(copy.deepcopy(self._last))
        try:
            current = self._read(min(deadline, self.monotonic() + SECONDS))
        except OSError:
            current = empty_sample("upstream_unavailable")
        with self._lock:
            if self._closed:
                return Sample(empty_sample("source_failed"))
            error = current["error"]
            if error and error != "author_identity_mismatch":
                if not current["budgets"]:
                    current["budgets"] = copy.deepcopy(self._last["budgets"])
                if current["verified_identity"] is None and self._last["verified_identity"]:
                    current.update(verified_identity=AUTHOR, identity_evidence="last_viewer_verified")
                    for row in current["budgets"].values():
                        row["identity_evidence"] = "last_viewer_verified"
            self._failures = self._failures + 1 if error else 0
            delay = min(900, 60 * 2 ** min(self._failures - 1, 4)) if error else 60
            row = current["budgets"].get("graphql", {})
            if row.get("primary_exhausted") and row.get("reset", 0) > self.clock():
                delay = max(delay, row["reset"] - self.clock())
            if row.get("secondary_limited"):
                delay = max(delay, row.get("retry_after", 0), 60)
            self._blocked = self.clock() + delay
            current["retry_at"] = self._blocked
            self._last = copy.deepcopy(current)
            return Sample(current)

    def close(self):
        with self._lock:
            self._closed = True
            process = self._process
        try:
            if process is not None:
                self._kill(process)
        finally:
            if self.workspace is not None:
                shutil.rmtree(self.workspace, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--agent", choices=("codex", "claude", "cursor"), required=True)
    parser.add_argument("--deadline", type=float, required=True)
    args = parser.parse_args()
    result = empty_sample("deadline_exceeded")
    if math.isfinite(args.deadline) and time.monotonic() < args.deadline <= time.monotonic() + SECONDS:
        result = measure(Path(args.root), args.cache_dir, args.agent, dict(os.environ), args.deadline)
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))


if __name__ == "__main__":
    main()
