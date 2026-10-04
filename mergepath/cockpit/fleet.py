"""Complete, bounded read-only audits with private reviewer-only cache ownership."""

import configparser
import copy
import datetime
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time

from .github import ClientError
from .inventory import REPO
from .prs import partial_row
from .scheduler import Sample

TOTAL_SECONDS = 180
MAX_STDOUT = 8 * 1024 * 1024
MAX_STDERR = 256 * 1024
MAX_PATHS = 10000
UTILITY_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
STATUSES = {"in-sync", "drift", "ahead", "override-only", "fetch-error"}
DIRECTIONS = {"hub ahead", "consumer ahead of hub", "re-render differs",
              "covered by .sync-overrides.yml", "unverified divergence"}
SHA = re.compile(r"[0-9a-f]{40}\Z")


def text(value, limit=4096):
    return type(value) is str and 0 < len(value) <= limit and not any(ord(c) < 32 for c in value)


def utc_epoch(value):
    if type(value) is not str or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", value):
        raise ValueError("invalid_audit_time")
    result = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    if not math.isfinite(result) or result < 0:
        raise ValueError("invalid_audit_time")
    return result


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def validate_record(record, entry):
    """Preserve the CLI object, rejecting unsupported/incoherent evidence."""
    required = {"schema_version", "name", "repo", "visibility", "baseline", "baseline_info",
                "hub_sha", "status", "paths", "open_sync_prs", "error", "audited_at"}
    if (type(record) is not dict or set(record) != required or type(record["schema_version"]) is not int
            or record["schema_version"] != 1 or record["name"] != entry.name or record["repo"] != entry.repo
            or record["visibility"] not in (None, "public", "private", "internal")
            or record["status"] not in STATUSES or type(record["paths"]) is not list
            or len(record["paths"]) > MAX_PATHS
            or record["hub_sha"] is not None and not (type(record["hub_sha"]) is str and SHA.fullmatch(record["hub_sha"]))):
        raise ValueError("invalid_audit_record")
    utc_epoch(record["audited_at"])
    baseline = record["baseline_info"]
    if baseline is None:
        if record["baseline"] is not None or record["status"] != "fetch-error":
            raise ValueError("invalid_baseline")
    elif (type(baseline) is not dict or set(baseline) != {"ref", "sha", "kind", "refreshed", "dirty", "warnings"}
          or not text(baseline["ref"], 1024) or baseline["kind"] != "cache-clone"
          or baseline["refreshed"] is not True or type(baseline["dirty"]) is not bool
          or type(baseline["warnings"]) is not list or len(baseline["warnings"]) > 32
          or any(not text(w, 1024) for w in baseline["warnings"])
          or type(baseline["sha"]) is not str or not SHA.fullmatch(baseline["sha"])
          or record["baseline"] != f'{baseline["ref"]}@{baseline["sha"]}'):
        raise ValueError("invalid_baseline")
    paths = set()
    for path in record["paths"]:
        if (type(path) is not dict or set(path) != {"path", "class", "direction", "comparison", "override_reason", "provenance"}
                or not text(path["path"]) or Path(path["path"]).is_absolute()
                or ".." in Path(path["path"]).parts or path["path"] in paths
                or path["class"] not in {"canonical", "kit", "templated"}
                or path["direction"] not in DIRECTIONS or not text(path["comparison"], 1024)
                or path["override_reason"] is not None and not text(path["override_reason"], 4096)):
            raise ValueError("invalid_audit_path")
        paths.add(path["path"])
        provenance = path["provenance"]
        if provenance is not None:
            sha_keys = {"source_sha", "sync_sha", "hub_sha", "consumer_sha"}
            entry_keys = {"source_entry", "hub_entry", "consumer_entry"}
            if (type(provenance) is not dict or set(provenance) != sha_keys | entry_keys
                    or any(type(provenance[k]) is not str or not SHA.fullmatch(provenance[k]) for k in sha_keys)
                    or any(type(provenance[k]) is not str or len(provenance[k]) > 8192
                           or not re.fullmatch(r"100(?:644|755) blob [0-9a-f]{40}\t[^\x00-\x1f]+", provenance[k]) for k in entry_keys)):
                raise ValueError("invalid_provenance")
    prs, identities = record["open_sync_prs"], set()
    if prs is not None:
        if type(prs) is not list or len(prs) > 1000:
            raise ValueError("invalid_sync_prs")
        for pr in prs:
            if (type(pr) is not dict or set(pr) != {"number", "branch", "state", "lifecycle_state", "draft"}
                    or type(pr["number"]) is not int or not 1 <= pr["number"] <= 9007199254740991
                    or pr["number"] in identities or not text(pr["branch"], 1024)
                    or not pr["branch"].startswith("mergepath-sync/") or not text(pr["state"], 128)
                    or pr["lifecycle_state"] != "OPEN" or type(pr["draft"]) is not bool):
                raise ValueError("invalid_sync_prs")
            identities.add(pr["number"])
    error = record["error"]
    if record["status"] == "fetch-error":
        if (type(error) is not dict or set(error) != {"source", "reason"}
                or error["source"] not in {"consumer", "open_sync_prs"} or not text(error["reason"], 512)):
            raise ValueError("invalid_audit_error")
    elif error is not None or prs is None or baseline is None or record["hub_sha"] is None:
        raise ValueError("missing_audit_evidence")
    if record["status"] != "fetch-error":
        directions = {p["direction"] for p in record["paths"]}
        derived = ("ahead" if "consumer ahead of hub" in directions else
                   "drift" if directions - {"covered by .sync-overrides.yml"} else
                   "override-only" if directions else "in-sync")
        if derived != record["status"]:
            raise ValueError("incoherent_audit_status")
    return record


def parse_audit(output, code, inventory):
    if code not in (0, 1, 3) or type(output) is not bytes or len(output) > MAX_STDOUT:
        raise ClientError("source_failed")
    try:
        value = output.decode("utf-8")
        if value and not value.endswith("\n"):
            raise ValueError("incomplete_ndjson")
        lines = value[:-1].split("\n") if value else []
        consumers = tuple(entry for entry in inventory if not entry.hub)
        if len(lines) != len(consumers):
            raise ValueError("incomplete_fleet")
        records, expected = {}, {entry.repo: entry for entry in consumers}
        for line in lines:
            record = json.loads(line, object_pairs_hook=_unique_object,
                                parse_constant=lambda value: (_ for _ in ()).throw(ValueError()))
            if type(record) is not dict or record.get("repo") not in expected or record["repo"] in records:
                raise ValueError("invalid_fleet_identity")
            records[record["repo"]] = validate_record(record, expected[record["repo"]])
        statuses = {record["status"] for record in records.values()}
        expected_code = 3 if "fetch-error" in statuses else 1 if statuses & {"drift", "ahead"} else 0
        if code != expected_code:
            raise ValueError("incoherent_audit_exit")
        return [records[entry.repo] for entry in consumers]
    except (ValueError, TypeError, KeyError, OverflowError, RecursionError):
        raise ClientError("invalid_upstream_json") from None


def _regular_read(path, limit=65536):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("unsafe_cache")
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            raise ValueError("unsafe_cache")
        return data.decode("utf-8")
    finally:
        os.close(fd)


def _walk_error(error):
    raise error


class FleetProvider:
    def __init__(self, inventory, trusted_root, reviewer_token, *, cache_parent=None,
                 utilities=None, monotonic=time.monotonic):
        self.inventory = tuple(inventory)
        consumers = [entry for entry in self.inventory if not entry.hub]
        if (not consumers or len(consumers) > 256 or len([e for e in self.inventory if e.hub]) != 1
                or len({e.repo for e in self.inventory}) != len(self.inventory)
                or len({e.name for e in self.inventory}) != len(self.inventory)
                or any(not REPO.fullmatch(e.repo) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", e.name) for e in self.inventory)):
            raise ValueError("invalid_fleet_inventory")
        self.root = Path(trusted_root).resolve(strict=True)
        self.token = reviewer_token
        self.monotonic = monotonic
        self.tools = {tool: shutil.which(tool, path=UTILITY_PATH) for tool in ("bash", "git", "gh")}
        if utilities is not None:  # Trusted launch/test dependency injection, never browser input.
            self.tools = dict(utilities)
        if set(self.tools) != {"bash", "git", "gh"} or any(not value or not Path(value).is_absolute() for value in self.tools.values()):
            raise ValueError("fleet_tools_unavailable")
        parent = Path(cache_parent).resolve(strict=True) if cache_parent is not None else Path(tempfile.gettempdir()).resolve()
        self.workspace = Path(tempfile.mkdtemp(prefix="cockpit-fleet-", dir=parent))
        try:
            self.workspace.chmod(0o700)
            for name in ("cache", "home", "gh", "xdg", "tmp", "templates", "bin"):
                (self.workspace / name).mkdir(mode=0o700)
            for tool, executable in self.tools.items():
                (self.workspace / "bin" / tool).symlink_to(executable)
            self.cache = self.workspace / "cache"
            (self.workspace / "gh/config.yml").write_text("git_protocol: https\n")
        except BaseException:
            shutil.rmtree(self.workspace, ignore_errors=True)
            raise
        self._lock, self._last, self._process, self._closed = threading.Lock(), {}, None, False

    def _environment(self):
        if type(self.token) is not str or not self.token.strip() or "\x00" in self.token:
            raise ClientError("cached_reviewer_credential_required")
        env = {"PATH": str(self.workspace / "bin") + ":" + UTILITY_PATH,
               "HOME": str(self.workspace / "home"), "GH_CONFIG_DIR": str(self.workspace / "gh"),
               "XDG_CONFIG_HOME": str(self.workspace / "xdg"), "XDG_CACHE_HOME": str(self.workspace / "xdg"),
               "TMPDIR": str(self.workspace / "tmp"), "MERGEPATH_SYNC_CACHE": str(self.cache),
               "GH_TOKEN": self.token, "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat",
               "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": os.devnull,
               "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
               "SSH_ASKPASS": "/usr/bin/false"}
        settings = [("credential.helper", ""), ("credential.https://github.com.helper", "!" + shlex.quote(self.tools["gh"]) + " auth git-credential"),
                    ("credential.https://github.com.useHttpPath", "true"), ("core.hooksPath", os.devnull),
                    ("core.fsmonitor", "false"), ("init.templateDir", str(self.workspace / "templates")),
                    ("protocol.file.allow", "never"), ("protocol.ext.allow", "never"), ("protocol.ssh.allow", "never")]
        env["GIT_CONFIG_COUNT"] = str(len(settings))
        for index, (key, value) in enumerate(settings):
            env[f"GIT_CONFIG_KEY_{index}"], env[f"GIT_CONFIG_VALUE_{index}"] = key, value
        return env

    def _check_cache(self, deadline):
        expected = {entry.name: entry.repo for entry in self.inventory if not entry.hub}
        if self.cache.is_symlink() or not self.cache.is_dir():
            raise ValueError("unsafe_cache")
        for child in self.cache.iterdir():
            if self.monotonic() >= deadline:
                raise ClientError("deadline_exceeded")
            if child.name not in expected or child.is_symlink() or not child.is_dir():
                raise ValueError("unsafe_cache")
            gitdir = child / ".git"
            if gitdir.is_symlink() or not gitdir.is_dir():
                raise ValueError("unsafe_cache")
            count = 0
            for directory, dirs, files in os.walk(gitdir, followlinks=False, onerror=_walk_error):
                for name in dirs + files:
                    count += 1
                    if count > 8192 or self.monotonic() >= deadline:
                        raise ClientError("deadline_exceeded")
                    path = Path(directory) / name
                    mode = path.lstat().st_mode
                    if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)) or path.name in {"alternates", "commondir"}:
                        raise ValueError("unsafe_cache")
            parser = configparser.RawConfigParser(strict=True)
            parser.read_string(_regular_read(gitdir / "config"))
            if parser.defaults():
                raise ValueError("unsafe_cache")
            origin = None
            for section in parser.sections():
                for key, value in parser.items(section):
                    if section == "core" and key in {"repositoryformatversion", "filemode", "bare", "logallrefupdates", "ignorecase", "precomposeunicode"}:
                        if key == "bare" and value != "false":
                            raise ValueError("unsafe_cache")
                    elif section == 'remote "origin"' and key in {"url", "fetch"}:
                        if key == "url":
                            origin = value
                        elif not re.fullmatch(r"\+refs/heads/[^\s:]+:refs/remotes/origin/[^\s:]+", value):
                            raise ValueError("unsafe_cache")
                    elif re.fullmatch(r'branch "[^"\n]+"', section) and ((key == "remote" and value == "origin") or (key == "merge" and re.fullmatch(r"refs/heads/[^\s]+", value))):
                        pass
                    else:
                        raise ValueError("unsafe_cache")
            if origin not in {f"https://github.com/{expected[child.name]}", f"https://github.com/{expected[child.name]}.git"}:
                raise ValueError("unsafe_cache")

    def _run(self, deadline, env):
        command = [self.tools["bash"], str(self.root / "scripts/sync-to-downstream.sh"), "--audit", "--json"]
        process = subprocess.Popen(command, cwd=self.root, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self._process = process
        chunks, sizes = {"out": [], "err": []}, {"out": 0, "err": 0}
        try:
            with selectors.DefaultSelector() as selector:
                for pipe, name in ((process.stdout, "out"), (process.stderr, "err")):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ, name)
                while selector.get_map():
                    remaining = deadline - self.monotonic()
                    if remaining <= 0 or self._closed:
                        raise ClientError("deadline_exceeded")
                    for key, _ in selector.select(min(.05, remaining)):
                        data = os.read(key.fd, 65536)
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        name = key.data
                        sizes[name] += len(data)
                        if sizes[name] > (MAX_STDOUT if name == "out" else MAX_STDERR):
                            raise ClientError("response_too_large")
                        if name == "out":
                            chunks[name].append(data)
                remaining = deadline - self.monotonic()
                if remaining <= 0:
                    raise ClientError("deadline_exceeded")
                return process.wait(timeout=remaining), b"".join(chunks["out"])
        except subprocess.TimeoutExpired:
            raise ClientError("deadline_exceeded") from None
        finally:
            # Always kill the group: a leader can exit while children retain pipes/cache access.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=1)
            process.stdout.close()
            process.stderr.close()
            self._process = None

    def fetch(self, deadline):
        if not self._lock.acquire(blocking=False):
            raise ClientError("upstream_backoff")
        try:
            deadline = min(deadline, self.monotonic() + TOTAL_SECONDS)
            if self._closed or deadline <= self.monotonic():
                raise ClientError("deadline_exceeded")
            env = self._environment()
            self._check_cache(deadline)
            code, output = self._run(deadline, env)
            records = parse_audit(output, code, self.inventory)
            if self.monotonic() >= deadline or self._closed:
                raise ClientError("deadline_exceeded")
            last, rows = copy.deepcopy(self._last), []
            for record in records:
                if self.monotonic() >= deadline or self._closed:
                    raise ClientError("deadline_exceeded")
                repo, failed = record["repo"], record["status"] == "fetch-error"
                if not failed:
                    last[repo] = copy.deepcopy(record)
                retained = copy.deepcopy(last.get(repo)) if failed else copy.deepcopy(record)
                observed = utc_epoch(retained["audited_at"]) if retained else None
                partial_prs = []
                for pr in retained["open_sync_prs"] or [] if retained else []:
                    if self.monotonic() >= deadline or self._closed:
                        raise ClientError("deadline_exceeded")
                    row = partial_row(repo, str(pr["number"]), title="Sync PR · " + pr["branch"], merge_state=pr["state"], draft=pr["draft"], observed_at=observed)
                    row["stale"], row["hazards"] = failed, []
                    partial_prs.append(row)
                rows.append({"name": record["name"], "repo": repo, "status": record["status"],
                             "record": retained, "attempt": copy.deepcopy(record), "observed_at": observed,
                             "attempted_at": utc_epoch(record["audited_at"]), "stale": failed,
                             "sync_pr_rows": partial_prs})
            if self.monotonic() >= deadline or self._closed:
                raise ClientError("deadline_exceeded")
            self._last = last
            return Sample({"schema": "cockpit-fleet/v1", "hub_repo": next(e.repo for e in self.inventory if e.hub),
                           "repositories": rows, "complete": code != 3,
                           "audit_exit": code}, hot=False)
        except (OSError, ValueError, configparser.Error):
            raise ClientError("source_failed") from None
        finally:
            self._lock.release()

    def close(self):
        self._closed = True
        process = self._process
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # Wait for the owner before removing its cache; never race a child reset.
        with self._lock:
            self.token = None
            if self.workspace.exists():
                shutil.rmtree(self.workspace)
