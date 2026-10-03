"""Session-bound previews and a single, bounded confirmed-sync worker."""

import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import shutil
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

from .fleet import SHA, UTILITY_PATH, validate_record
from .inventory import HUB, REPO

PREVIEW_SECONDS = 180
PREVIEW_TTL = 300
RUN_SECONDS = 900
MAX_EVENTS = 1500
MAX_LOG_BYTES = 256 * 1024
MAX_LINE = 4096
STAGES = ("fetch", "diff", "branch", "commit", "PR")


class SyncError(ValueError):
    """Stable public refusal category; never carry subprocess diagnostics."""


def plain_environment(workspace, tools):
    """An allowlist, rather than a blacklist of ambient credential selectors."""
    env = {"PATH": str(workspace / "bin") + ":" + UTILITY_PATH,
           "HOME": str(workspace / "home"), "XDG_CONFIG_HOME": str(workspace / "config"),
           "XDG_CACHE_HOME": str(workspace / "cache"), "GH_CONFIG_DIR": str(workspace / "gh"),
           "TMPDIR": str(workspace / "tmp"), "LC_ALL": "C", "GH_HOST": "github.com",
           "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0",
           "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": os.devnull, "GIT_CONFIG_GLOBAL": os.devnull}
    settings = [("credential.helper", ""), ("credential.https://github.com.helper", "!" + shlex.quote(str(tools["gh"])) + " auth git-credential"),
                ("credential.https://github.com.useHttpPath", "true"), ("core.hooksPath", os.devnull),
                ("core.fsmonitor", "false"), ("init.templateDir", str(workspace / "templates")),
                ("protocol.file.allow", "never"), ("protocol.ext.allow", "never"), ("protocol.ssh.allow", "never")]
    env["GIT_CONFIG_COUNT"] = str(len(settings))
    for i, (key, value) in enumerate(settings):
        env[f"GIT_CONFIG_KEY_{i}"], env[f"GIT_CONFIG_VALUE_{i}"] = key, value
    return env


def workspace_at(parent=None):
    workspace = Path(tempfile.mkdtemp(prefix="cockpit-sync-", dir=parent))
    try:
        workspace.chmod(0o700)
        for name in ("bin", "home", "config", "cache", "gh", "tmp", "templates"):
            (workspace / name).mkdir(mode=0o700)
        (workspace / "gh/config.yml").write_text("git_protocol: https\n")
        return workspace
    except BaseException:
        shutil.rmtree(workspace, ignore_errors=True)
        raise


def validate_git_identity(value):
    if (type(value) is not dict or set(value) != {"name", "email", "signing"}
            or type(value["name"]) is not str or not 0 < len(value["name"]) <= 256
            or value["name"] != value["name"].strip() or any(ord(c) < 32 for c in value["name"])
            or type(value["email"]) is not str or len(value["email"]) > 256
            or not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+", value["email"])
            or type(value["signing"]) is not bool):
        raise SyncError("git_identity_unavailable")
    if value["signing"]:
        raise SyncError("unsupported_git_signing")
    return copy.deepcopy(value)


def resolve_git_identity(git):
    """Read only public GLOBAL settings once; no repo/ambient identity fallback."""
    env = {"PATH": UTILITY_PATH, "HOME": str(Path.home()), "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": os.devnull}
    def get(key, boolean=False):
        try:
            command = [git, "config", "--global"] + (["--bool"] if boolean else []) + ["--get-all", key]
            result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=5)
            if result.returncode == 1:
                return None
            if result.returncode != 0 or len(result.stdout) > 1024:
                raise SyncError("git_identity_unavailable")
            values = result.stdout.decode("utf-8").splitlines()
            if len(values) != 1:
                raise SyncError("git_identity_unavailable")
            return values[0]
        except (OSError, UnicodeError, subprocess.SubprocessError):
            raise SyncError("git_identity_unavailable") from None
    signing = get("commit.gpgsign", True)
    if signing not in (None, "false", "true"):
        raise SyncError("git_identity_unavailable")
    return validate_git_identity({"name": get("user.name"), "email": get("user.email"), "signing": signing == "true"})


def author_environment(env, identity):
    identity = validate_git_identity(identity)
    env = dict(env)
    # Explicit author and committer prevent clone-local or OS-guessed bylines.
    env.update(GIT_AUTHOR_NAME=identity["name"], GIT_AUTHOR_EMAIL=identity["email"],
               GIT_COMMITTER_NAME=identity["name"], GIT_COMMITTER_EMAIL=identity["email"])
    count = int(env.get("GIT_CONFIG_COUNT", "0"))
    for key, value in (("user.name", identity["name"]), ("user.email", identity["email"]),
                       ("user.useConfigOnly", "true"), ("commit.gpgsign", "false")):
        env[f"GIT_CONFIG_KEY_{count}"], env[f"GIT_CONFIG_VALUE_{count}"] = key, value
        count += 1
    env["GIT_CONFIG_COUNT"] = str(count)
    return env


def hub_identity(root, git, env, deadline, *, inherit_group=False):
    def query(*args):
        process = None
        try:
            if time.monotonic() >= deadline:
                raise SyncError("deadline_exceeded")
            end = min(deadline, time.monotonic() + 5)
            process = subprocess.Popen([git, "-C", str(root), *args], env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=not inherit_group)
            chunks, sizes = [], {"out": 0, "err": 0}
            with selectors.DefaultSelector() as selector:
                for pipe, name in ((process.stdout, "out"), (process.stderr, "err")):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ, name)
                while selector.get_map():
                    if time.monotonic() >= end:
                        raise SyncError("hub_unavailable")
                    for key, _ in selector.select(.05):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        sizes[key.data] += len(chunk)
                        if sizes[key.data] > 1024 * 1024:
                            raise SyncError("hub_unavailable")
                        if key.data == "out":
                            chunks.append(chunk)
            if process.wait(timeout=max(.001, end - time.monotonic())) != 0:
                raise SyncError("hub_unavailable")
            return b"".join(chunks).decode("utf-8").strip()
        except (OSError, UnicodeError, subprocess.SubprocessError):
            raise SyncError("hub_unavailable") from None
        finally:
            if process is not None:
                if inherit_group:
                    if process.poll() is None:
                        process.kill()
                else:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.wait(timeout=2)
                process.stdout.close()
                process.stderr.close()
    if query("symbolic-ref", "--short", "HEAD") != "main":
        raise SyncError("hub_not_main")
    if query("status", "--porcelain", "--untracked-files=all"):
        raise SyncError("hub_dirty")
    sha = query("rev-parse", "--verify", "HEAD^{commit}")
    if not SHA.fullmatch(sha) or sha != query("rev-parse", "--verify", "refs/remotes/origin/main^{commit}"):
        raise SyncError("hub_not_origin_main")
    if query("remote", "get-url", "origin") not in (f"https://github.com/{HUB}", f"https://github.com/{HUB}.git"):
        raise SyncError("hub_origin_mismatch")
    return sha


def fingerprint(root):
    path = root / ".mergepath-sync.yml"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise SyncError("manifest_unavailable")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def condition(record):
    """Only evidence that can change write authority, excluding audit timestamps."""
    return {key: copy.deepcopy(record[key]) for key in ("repo", "hub_sha", "baseline", "baseline_info", "status", "paths", "open_sync_prs")}


def scrub(value):
    value = re.sub(r"(?i)authorization\s*[:=].*", "[redacted]", value)
    value = re.sub(r"(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+", "[redacted]", value)
    value = re.sub(r"(?i)(?:authorization|(?:gh|github|op_preflight)[a-z_]*token|op_preflight_[a-z_]*pat)\s*[:=]\s*\S+", "[redacted]", value)
    value = re.sub(r"https?://[^\s/@]+:[^\s/@]+@", "https://[redacted]@", value)
    return "".join(c for c in value if c in "\t" or ord(c) >= 32)[:MAX_LINE]


class SyncProvider:
    def __init__(self, inventory, trusted_root, fleet_fetch, *, cache_dir, agent="codex",
                 operator="nathanjohnpayne", changed=lambda: None, completed=lambda: None,
                 tools=None, clock=time.time, monotonic=time.monotonic, lock_parent=None, audit_log=None, git_identity=None):
        self.inventory = tuple(inventory)
        self.entries = {e.repo: e for e in self.inventory if not e.hub}
        if (not self.entries or len(self.entries) != len(self.inventory) - 1
                or len(self.entries) > 256 or next((e.repo for e in self.inventory if e.hub), None) != HUB
                or any(not REPO.fullmatch(e.repo) for e in self.inventory)
                or agent not in ("codex", "claude", "cursor") or operator != "nathanjohnpayne"):
            raise ValueError("invalid_sync_launch")
        self.root = Path(trusted_root).resolve(strict=True)
        self.cache_dir = str(Path(cache_dir).resolve())
        self.audit_log = Path(os.path.abspath(audit_log)) if audit_log is not None else Path(self.cache_dir) / "cockpit-sync.jsonl"
        self.fetch, self.changed, self.completed = fleet_fetch, changed, completed
        self.agent, self.operator, self.clock, self.monotonic = agent, operator, clock, monotonic
        self.tools = {name: shutil.which(name, path=UTILITY_PATH) for name in ("bash", "git", "gh")}
        self.tools["python"] = sys.executable
        if tools is not None:  # Fixed launch/test dependency injection; never request input.
            self.tools = dict(tools)
        if set(self.tools) != {"bash", "git", "gh", "python"} or any(not x or not Path(x).is_absolute() for x in self.tools.values()):
            raise ValueError("sync_tools_unavailable")
        try:
            self.git_identity = resolve_git_identity(self.tools["git"]) if git_identity is None else validate_git_identity(git_identity)
            self.availability_error = None
        except SyncError as error:
            self.git_identity, self.availability_error = None, str(error)
        self.workspace = workspace_at()
        try:
            for name, executable in self.tools.items():
                (self.workspace / "bin" / name).symlink_to(executable)
            # All launches for the same canonical checkout share a uid-owned lock.
            parent = Path(lock_parent or tempfile.gettempdir()).resolve()
            self.lock_path = parent / f"mergepath-cockpit-sync-{os.getuid()}-{hashlib.sha256(str(self.root).encode()).hexdigest()}.lock"
            self._mutex = threading.RLock()
            self._state = {"schema": "cockpit-sync/v1", "phase": "idle", "preview": None, "run": None, "error": None}
            self._session = self._preview = self._process = self._thread = self._lock_fd = None
            self._closed = False
            self._cleanup_incomplete = False
            self._bytes = 0
        except BaseException:
            shutil.rmtree(self.workspace, ignore_errors=True)
            raise

    def _publish(self):
        self.changed()

    def snapshot(self, session_id):
        with self._mutex:
            if self._session is not None and session_id != self._session:
                return {"schema": "cockpit-sync/v1", "phase": "idle", "preview": None, "run": None, "error": None}
            state = copy.deepcopy(self._state)
            if state["phase"] == "preview" and self._preview and self.monotonic() >= self._preview["deadline"]:
                state["phase"], state["error"] = "error", "preview_expired"
                state["preview"]["can_confirm"] = False
            return state

    def _targets(self, payload):
        if type(payload) is not dict or set(payload) != {"repos"} or type(payload["repos"]) is not list:
            raise SyncError("invalid_targets")
        repos = payload["repos"]
        if (not repos or len(repos) > len(self.entries) or any(type(r) is not str or r not in self.entries for r in repos)
                or len(set(repos)) != len(repos)):
            raise SyncError("invalid_targets")
        return [repo for repo in self.entries if repo in repos]

    def preview(self, session_id, payload):
        repos = self._targets(payload)
        if self.availability_error is not None:
            raise SyncError(self.availability_error)
        if type(session_id) is not str or not session_id:
            raise SyncError("invalid_session")
        with self._mutex:
            if self._cleanup_incomplete:
                raise SyncError("cleanup_incomplete")
            if self._closed or self._state["phase"] in ("previewing", "running") or self._thread is not None and self._thread.is_alive():
                raise SyncError("sync_busy")
            self._session, self._preview = session_id, None
            self._state = {"schema": "cockpit-sync/v1", "phase": "previewing", "preview": None, "run": None, "error": None}
            self._thread = threading.Thread(target=self._make_preview, args=(repos,), daemon=True)
            self._thread.start()
        self._publish()
        return self.snapshot(session_id)

    def _records(self, deadline):
        sample = self.fetch(deadline)
        data = sample.data
        if type(data) is not dict or data.get("schema") != "cockpit-fleet/v1" or data.get("hub_repo") != HUB:
            raise SyncError("audit_unavailable")
        rows = data.get("repositories")
        if type(rows) is not list or len(rows) != len(self.entries):
            raise SyncError("audit_incomplete")
        records = {}
        for row in rows:
            repo = row.get("repo") if type(row) is dict else None
            if repo not in self.entries or repo in records:
                raise SyncError("audit_incomplete")
            record = copy.deepcopy(validate_record(row.get("attempt"), self.entries[repo]))
            if row.get("stale") is not False and record["status"] != "fetch-error":
                raise SyncError("audit_stale")
            records[repo] = record
        return records

    def _make_preview(self, repos):
        try:
            deadline = self.monotonic() + PREVIEW_SECONDS
            env = plain_environment(self.workspace, self.tools)
            sha = hub_identity(self.root, self.tools["git"], env, deadline)
            manifest = fingerprint(self.root)
            records = self._records(deadline)
            with self._mutex:
                if self._closed or self._state["phase"] != "previewing":
                    return
            targets = []
            for repo in repos:
                record = records[repo]
                good = (record["status"] in ("drift", "ahead") and record["hub_sha"] == sha
                        and record["baseline_info"] is not None and not record["baseline_info"]["dirty"]
                        and record["open_sync_prs"] is not None)
                targets.append({"name": self.entries[repo].name, "repo": repo, "status": record["status"],
                                "eligible": good, "reason": None if good else "audit_refuses_target",
                                "baseline": record["baseline"], "paths": record["paths"], "open_sync_prs": record["open_sync_prs"],
                                "ahead": any(p["direction"] == "consumer ahead of hub" for p in record["paths"]),
                                "choices": ["skip", "recreate"] if good and record["open_sync_prs"] else ["sync", "skip"] if good else ["skip"],
                                "default_choice": "skip" if not good or record["open_sync_prs"] else "sync"})
            dry = self._capture([self.tools["bash"], str(self.root / "scripts/sync-to-downstream.sh"), "--sync-all", "--repos", ",".join(repos), "--dry-run"], env, deadline)
            if hub_identity(self.root, self.tools["git"], env, deadline) != sha or fingerprint(self.root) != manifest:
                raise SyncError("preview_changed")
            with self._mutex:
                if self._closed or self._state["phase"] != "previewing":
                    return
                preview = {"schema": "cockpit-sync-preview/v1", "preview_id": secrets.token_urlsafe(32), "hub_sha": sha,
                           "expires_at": self.clock() + PREVIEW_TTL, "targets": targets, "checks": ["Hub clean at origin/main", "Fresh consumer baselines and complete open PR lookup"],
                           "dry_run": dry, "scope_note": "Dry run proposes manifest scope; audited paths show refreshed remote differences and overrides.",
                           "can_confirm": any(t["eligible"] for t in targets)}
                self._preview = {"public": copy.deepcopy(preview), "deadline": self.monotonic() + PREVIEW_TTL,
                                 "manifest": manifest, "records": records, "nonce": secrets.token_hex(16)}
                self._state.update(phase="preview", preview=preview)
        except Exception as error:
            with self._mutex:
                if self._state["phase"] == "previewing":
                    self._state.update(phase="error", error=str(error) if isinstance(error, SyncError) else "preview_unavailable")
        finally:
            self._publish()

    def _capture(self, command, env, deadline):
        chunks, size = [], 0
        process = subprocess.Popen(command, cwd=self.root, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self._process = process
        try:
            with selectors.DefaultSelector() as selector:
                os.set_blocking(process.stdout.fileno(), False)
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if self._closed or self.monotonic() >= deadline:
                        raise SyncError("deadline_exceeded")
                    for key, _ in selector.select(.05):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        size += len(chunk)
                        if size > MAX_LOG_BYTES:
                            raise SyncError("output_limit")
                        chunks.append(chunk)
            if process.wait(timeout=max(.001, deadline - self.monotonic())) != 0:
                raise SyncError("dry_run_failed")
            output = "\n".join(scrub(line) for line in b"".join(chunks).decode("utf-8", "replace").splitlines())
            if len(output.encode()) > MAX_LOG_BYTES:
                raise SyncError("output_limit")
            return output
        finally:
            self._reap(process)

    def _acquire(self):
        fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise SyncError("lock_unavailable")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(fd)
            raise SyncError("sync_busy") from None
        self._lock_fd = fd

    def _journal(self, run, event):
        """Append public action identity, never a capability, path or credential."""
        item = {"schema": "cockpit-sync-action/v1", "event": event, "run_id": run["run_id"],
                "operator": run["operator"], "time": self.clock(), "hub_sha": run["hub_sha"],
                "repos": run["repos"], "choices": run["choices"], "outcome": run["outcome"]}
        fd = None
        try:
            self.audit_log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(self.audit_log, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise OSError()
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            line = (json.dumps(item, allow_nan=False) + "\n").encode()
            if os.write(fd, line) != len(line):
                raise OSError()
            os.fsync(fd)
        except OSError:
            raise SyncError("audit_log_unavailable") from None
        finally:
            if fd is not None:
                os.close(fd)

    def confirm(self, session_id, payload):
        with self._mutex:
            if type(payload) is not dict or set(payload) != {"preview_id", "hub_sha", "choices", "ack_ahead"}:
                raise SyncError("invalid_confirmation")
            if session_id != self._session or self._preview is None:
                raise SyncError("preview_unavailable")
            preview = self._preview
            public = preview["public"]
            if payload["preview_id"] != public["preview_id"] or payload["hub_sha"] != public["hub_sha"]:
                raise SyncError("preview_mismatch")
            if self._state["phase"] == "running" or self._state["run"] is not None:
                raise SyncError("preview_consumed")
            if self._closed or self._state["phase"] != "preview" or self.monotonic() >= preview["deadline"]:
                raise SyncError("preview_expired")
            choices = payload["choices"]
            if type(choices) is not dict or set(choices) != {t["repo"] for t in public["targets"]} or type(payload["ack_ahead"]) is not bool:
                raise SyncError("invalid_choices")
            for target in public["targets"]:
                if choices[target["repo"]] not in target["choices"]:
                    raise SyncError("invalid_choices")
            selected = [t for t in public["targets"] if choices[t["repo"]] != "skip"]
            if not selected:
                raise SyncError("all_skipped")
            if any(t["ahead"] for t in selected) and not payload["ack_ahead"]:
                raise SyncError("ahead_ack_required")
            self._acquire()
            run = {"schema": "cockpit-sync-run/v1", "run_id": secrets.token_hex(16), "operator": self.operator,
                   "started_at": self.clock(), "hub_sha": public["hub_sha"], "repos": [t["repo"] for t in selected],
                   "choices": copy.deepcopy(choices), "events": [], "results": [], "outcome": "running"}
            try:
                self._journal(run, "started")
            except BaseException:
                os.close(self._lock_fd)
                self._lock_fd = None
                raise
            self._state.update(phase="running", run=run, error=None)
            self._bytes = 0
            plan = {"hub_sha": public["hub_sha"], "manifest": preview["manifest"], "nonce": preview["nonce"],
                    "git_identity": copy.deepcopy(self.git_identity),
                    "targets": [{"repo": t["repo"], "name": t["name"], "choice": choices[t["repo"]],
                                 "expected": condition(preview["records"][t["repo"]])} for t in selected],
                    "inventory": [{"name": e.name, "repo": e.repo, "hub": e.hub} for e in self.inventory]}
            self._thread = threading.Thread(target=self._execute, args=(plan,), daemon=True)
            self._thread.start()
        self._publish()
        return self.snapshot(session_id)

    def cancel(self, session_id, payload):
        with self._mutex:
            if type(payload) is not dict or set(payload) != {"preview_id"} or session_id != self._session:
                raise SyncError("invalid_cancel")
            if self._state["phase"] == "running":
                raise SyncError("run_already_started")
            if self._state["phase"] == "previewing" and payload["preview_id"] is None:
                self._state.update(phase="canceled", preview=None)
            elif self._preview is None or payload["preview_id"] != self._preview["public"]["preview_id"]:
                raise SyncError("preview_unavailable")
            self._preview = None
            self._state.update(phase="canceled", preview=None)
        self._publish()
        return self.snapshot(session_id)

    def _event(self, item):
        with self._mutex:
            run = self._state["run"]
            if type(item) is not dict or item.get("kind") not in ("log", "stage", "result", "outcome"):
                raise SyncError("worker_protocol_error")
            kind = item["kind"]
            if kind == "log":
                if set(item) != {"kind", "text"} or type(item["text"]) is not str:
                    raise SyncError("worker_protocol_error")
                item["text"] = scrub(item["text"])
            elif kind in ("stage", "result"):
                if set(item) != {"kind", "repo", "value"} or item["repo"] not in run["repos"]:
                    raise SyncError("worker_protocol_error")
                value = item["value"]
                if type(value) is not str or (kind == "stage" and value not in STAGES):
                    raise SyncError("worker_protocol_error")
                if kind == "result":
                    if value not in ("no-change", "existing") and not re.fullmatch(r"https://github\.com/" + re.escape(item["repo"]) + r"/pull/[1-9][0-9]*", value):
                        raise SyncError("worker_protocol_error")
                    if any(r["repo"] == item["repo"] for r in run["results"]):
                        raise SyncError("worker_protocol_error")
                    run["results"].append(copy.deepcopy(item))
            elif set(item) != {"kind", "value"} or item["value"] not in ("success", "partial", "refused", "failed"):
                raise SyncError("worker_protocol_error")
            size = len(json.dumps(item).encode())
            if len(run["events"]) >= MAX_EVENTS or self._bytes + size > MAX_LOG_BYTES:
                raise SyncError("output_limit")
            self._bytes += size
            run["events"].append({"id": len(run["events"]) + 1, **item})
        self._publish()

    def _execute(self, plan):
        process, outcome = None, "failed"
        try:
            data = json.dumps(plan).encode()
            if len(data) > 1024 * 1024:
                raise SyncError("preview_plan_limit")
            deadline = self.monotonic() + RUN_SECONDS
            env = plain_environment(self.workspace, self.tools)
            command = [self.tools["python"], "-B", str(Path(__file__).with_name("sync_worker.py")),
                       "--root", str(self.root), "--cache-dir", self.cache_dir, "--agent", self.agent,
                       "--tools", json.dumps(self.tools), "--lock-fd", str(self._lock_fd)]
            process = subprocess.Popen(command, cwd=self.root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(self._lock_fd,))
            self._process = process
            os.set_blocking(process.stdin.fileno(), False)
            offset = 0
            with selectors.DefaultSelector() as writer:
                writer.register(process.stdin, selectors.EVENT_WRITE)
                while offset < len(data):
                    if self._closed or self.monotonic() >= deadline:
                        raise SyncError("deadline_exceeded")
                    if writer.select(.05):
                        offset += os.write(process.stdin.fileno(), data[offset:offset + 65536])
            process.stdin.close()
            buffer = b""
            with selectors.DefaultSelector() as selector:
                os.set_blocking(process.stdout.fileno(), False)
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if self._closed or self.monotonic() >= deadline:
                        raise SyncError("deadline_exceeded")
                    for key, _ in selector.select(.05):
                        data = os.read(key.fd, 65536)
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        buffer += data
                        if len(buffer) > MAX_LOG_BYTES:
                            raise SyncError("output_limit")
                        while b"\n" in buffer:
                            line, buffer = buffer.split(b"\n", 1)
                            item = json.loads(line)
                            self._event(item)
                            if item["kind"] == "outcome":
                                outcome = item["value"]
            code = process.wait(timeout=max(.001, deadline - self.monotonic()))
            if buffer or (outcome == "success" and (code != 0 or len(self._state["run"]["results"]) != len(plan["targets"]))):
                raise SyncError("worker_protocol_error")
            if outcome != "success" and self._state["run"]["results"]:
                outcome = "partial"
        except Exception as error:
            with self._mutex:
                self._state["error"] = str(error) if isinstance(error, SyncError) else "sync_failed"
                outcome = "partial" if self._state["run"]["results"] else "failed"
        finally:
            cleanup_complete = True
            if process is not None:
                try:
                    self._reap(process)
                except SyncError:
                    cleanup_complete = False
            with self._mutex:
                run = self._state["run"]
                if not cleanup_complete:
                    self._state["error"] = "cleanup_incomplete"
                    outcome = "partial" if run["results"] else "failed"
                run["outcome"], run["finished_at"] = outcome, self.clock()
                try:
                    self._journal(run, "finished")
                except SyncError:
                    if cleanup_complete:
                        self._state["error"] = "audit_log_unavailable"
                self._state["phase"] = "done" if outcome == "success" else "error"
                if cleanup_complete and self._lock_fd is not None:
                    os.close(self._lock_fd)
                    self._lock_fd = None
            self._publish()
            self.completed()

    @staticmethod
    def _signal_group(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return True
        except OSError:
            # A reaped leader is not proof that its descendants are gone.
            # Recover a failed signal only through independent group absence.
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                return True
            except OSError:
                pass
            return False
        return True

    def _reap(self, process):
        complete = self._signal_group(process)
        try:
            process.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            complete = False
        finally:
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe is not None:
                    try:
                        pipe.close()
                    except (OSError, ValueError):
                        complete = False
        with self._mutex:
            self._cleanup_incomplete = not complete
            if complete:
                self._process = None
            else:
                self._process = process
        if not complete:
            raise SyncError("cleanup_incomplete")

    def close(self):
        with self._mutex:
            self._closed = True
            process, thread = self._process, self._thread
        if process is not None:
            # Final reap owns proof and publication even if this signal fails.
            self._signal_group(process)
        if thread is not None and thread is not threading.current_thread():
            thread.join(PREVIEW_SECONDS + 3)
        if thread is not None and thread.is_alive():
            raise SyncError("cleanup_incomplete")
        if self._cleanup_incomplete:
            self._reap(self._process)
        with self._mutex:
            if self._lock_fd is not None:
                os.close(self._lock_fd)
                self._lock_fd = None
        if self.workspace.exists():
            shutil.rmtree(self.workspace)
