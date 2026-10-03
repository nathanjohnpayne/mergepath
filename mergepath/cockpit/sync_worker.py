"""Private cached-author subprocess. No credential crosses its stdout boundary."""

import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import sys
import time

# Executed by absolute trusted module path with a credential-free environment.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from mergepath.cockpit.fleet import FleetProvider, MAX_STDOUT, parse_audit
from mergepath.cockpit.inventory import HUB, Repository
from mergepath.cockpit.sync import (MAX_LINE, MAX_LOG_BYTES, RUN_SECONDS, STAGES, SyncError,
                                   author_environment, condition, fingerprint, hub_identity, scrub, validate_git_identity)


def emit(item):
    print(json.dumps(item, ensure_ascii=True, allow_nan=False), flush=True)


class Runner:
    """Children inherit the worker group; the parent always kills/reaps that group."""
    def __init__(self, deadline, lock_fd=None):
        self.deadline = deadline
        self.lock_fd = lock_fd

    def run(self, command, root, env, *, limit=MAX_LOG_BYTES, lines=None):
        process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   pass_fds=() if self.lock_fd is None else (self.lock_fd,))
        output, sizes, buffers = [], {"out": 0, "err": 0}, {"out": b"", "err": b""}
        try:
            with selectors.DefaultSelector() as selector:
                for pipe, name in ((process.stdout, "out"), (process.stderr, "err")):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ, name)
                while selector.get_map():
                    if time.monotonic() >= self.deadline:
                        raise SyncError("deadline_exceeded")
                    for key, _ in selector.select(.05):
                        data = os.read(key.fd, 65536)
                        name = key.data
                        if not data:
                            selector.unregister(key.fileobj)
                            if lines and buffers[name]:
                                lines(buffers[name].decode("utf-8", "replace"))
                            continue
                        sizes[name] += len(data)
                        if sizes[name] > limit:
                            raise SyncError("output_limit")
                        if name == "out" and not lines:
                            output.append(data)
                        if lines:
                            buffers[name] += data
                            while b"\n" in buffers[name]:
                                line, buffers[name] = buffers[name].split(b"\n", 1)
                                if len(line) > MAX_LINE * 2:
                                    raise SyncError("line_limit")
                                lines(line.decode("utf-8", "replace"))
                            if len(buffers[name]) > MAX_LINE * 2:
                                raise SyncError("line_limit")
            return process.wait(timeout=max(.001, self.deadline - time.monotonic())), b"".join(output)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
            process.stdout.close()
            process.stderr.close()


def cached_author(output):
    """Parse canonical export syntax as data; never evaluate it or cache files."""
    author = None
    try:
        for line in output.decode("utf-8").splitlines():
            if line.startswith("#") or not line.strip():
                continue
            words = shlex.split(line)
            if len(words) != 2 or words[0] != "export" or "=" not in words[1]:
                raise ValueError()
            key, value = words[1].split("=", 1)
            if not re.fullmatch(r"OP_PREFLIGHT_[A-Z_]+", key):
                raise ValueError()
            if key == "OP_PREFLIGHT_AUTHOR_PAT":
                if author is not None or not re.fullmatch(r"[A-Za-z0-9_]{1,1024}", value):
                    raise ValueError()
                author = value
        if not author:
            raise ValueError()
        return author
    except (UnicodeError, ValueError):
        raise SyncError("cached_author_required") from None


def execute(root, cache_dir, agent, tools, plan, lock_fd):
    identity = validate_git_identity(plan["git_identity"])
    inventory = tuple(Repository(**entry) for entry in plan["inventory"])
    if next((e.repo for e in inventory if e.hub), None) != HUB:
        raise SyncError("invalid_plan")
    # This private instance never publishes samples or retains a credential in the server.
    audit = FleetProvider(inventory, root, "not-loaded", utilities={k: tools[k] for k in ("bash", "git", "gh")})
    try:
        env = audit._environment()
        env.pop("GH_TOKEN")
        env["OP_PREFLIGHT_CACHE_DIR"] = cache_dir
        env["OP_PREFLIGHT_QUIET"] = "1"
        deadline = time.monotonic() + RUN_SECONDS - 5
        runner = Runner(deadline, lock_fd)
        # Refuse before even the cache helper if the confirmed immutable identity moved.
        def guard():
            if (hub_identity(root, tools["git"], env, deadline, inherit_group=True) != plan["hub_sha"]
                    or fingerprint(root) != plan["manifest"]):
                raise SyncError("preview_changed")
        guard()
        code, exports = Runner(min(deadline, time.monotonic() + 10), lock_fd).run(
            [tools["bash"], str(root / "scripts/op-preflight.sh"), "--agent", agent,
             "--mode", "review", "--check", "--print-exports"], root, env, limit=65536)
        if code != 0:
            raise SyncError("cached_author_required")
        author = cached_author(exports)
        exports = b""
        audit.token = author
        env = audit._environment()
        env.update(OP_PREFLIGHT_AUTHOR_PAT=author, OP_PREFLIGHT_CACHE_DIR=cache_dir,
                   OP_PREFLIGHT_QUIET="1", MERGEPATH_SYNC_AUTHORING_AGENT=agent)
        env = author_environment(env, identity)
        # No imported reviewer credential, auth fallback, test bypass, root override or trace.
        results = {}
        paths = (str(root), str(audit.workspace), cache_dir)
        log_bytes = 0
        def line(value):
            nonlocal log_bytes
            value = value.replace(author, "[redacted]")
            for path in paths:
                value = value.replace(path, "[local]")
            value = scrub(value)
            log_bytes += len(value.encode())
            if log_bytes > MAX_LOG_BYTES:
                raise SyncError("output_limit")
            if value.startswith("@@cockpit-sync\t"):
                event = json.loads(value.split("\t", 1)[1])
                if (type(event) is not dict or set(event) != {"kind", "repo", "value"}
                        or event["repo"] != target["repo"] or event["kind"] not in ("stage", "result")):
                    raise SyncError("worker_protocol_error")
                if event["kind"] == "stage" and event["value"] not in STAGES:
                    raise SyncError("worker_protocol_error")
                if event["kind"] == "result":
                    if event["value"] not in ("no-change", "existing") and not re.fullmatch(
                            r"https://github\.com/" + re.escape(target["repo"]) + r"/pull/[1-9][0-9]*", event["value"]):
                        raise SyncError("worker_protocol_error")
                    if target["repo"] in results:
                        raise SyncError("worker_protocol_error")
                    results[target["repo"]] = event["value"]
                emit(event)
            elif value:
                emit({"kind": "log", "text": value})
        for target in plan["targets"]:
            guard()
            audit._check_cache(deadline)
            code, output = runner.run([tools["bash"], str(root / "scripts/sync-to-downstream.sh"), "--audit", "--json"], root, env, limit=MAX_STDOUT)
            current = {r["repo"]: r for r in parse_audit(output, code, inventory)}
            if condition(current[target["repo"]]) != target["expected"]:
                raise SyncError("consumer_changed")
            guard()
            command = [tools["bash"], str(root / "scripts/sync-to-downstream.sh"), "--sync-all", "--repos", target["repo"],
                       "--expect-hub", plan["hub_sha"], "--expect-consumer", target["expected"]["baseline_info"]["sha"], "--progress-json"]
            if target["choice"] == "recreate":
                command += ["--fresh-branch", plan["nonce"]]
            code, _ = runner.run(command, root, env, lines=line)
            if code != 0 or target["repo"] not in results:
                emit({"kind": "outcome", "value": "partial" if results else "failed"})
                return 1
        emit({"kind": "outcome", "value": "success"})
        return 0
    finally:
        audit.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--agent", choices=("codex", "claude", "cursor"), required=True)
    parser.add_argument("--tools", required=True)
    parser.add_argument("--lock-fd", type=int, required=True)
    args = parser.parse_args()
    try:
        data = sys.stdin.buffer.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise SyncError("invalid_plan")
        plan = json.loads(data)
        return execute(Path(args.root).resolve(strict=True), str(Path(args.cache_dir).resolve()), args.agent, json.loads(args.tools), plan, args.lock_fd)
    except Exception as error:
        reason = str(error) if isinstance(error, SyncError) else "sync_failed"
        emit({"kind": "log", "text": reason})
        emit({"kind": "outcome", "value": "refused"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
