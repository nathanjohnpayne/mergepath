"""Fast local heartbeat observations; never reads accounting or GitHub."""

import copy
import json
import os
import re
import selectors
import signal
import subprocess
import tempfile
import time
from pathlib import Path

from .agents import LocalReader, number, provider, text
from .github import ClientError
from .scheduler import Sample

RUN_ID = re.compile(r"p4b-[A-Za-z0-9._-]{1,200}\Z")
STAGES = ("barrier", "adapter", "posting", "done")
MAX_RECORDS = 64
MAX_RECORD_BYTES = 65536
MAX_SCAN = 512
MAX_PROBE_BYTES = 4096
MAX_PROBES = 4


def resolve_live_directory(value=None):
    """Resolve once from operator configuration; no browser input accepted."""
    value = value if value is not None else str(Path.home() / ".local/state/mergepath/phase-4b-runs")
    if not text(value, 4096) or not Path(value).is_absolute():
        raise ValueError("invalid_live_directory")
    return Path(value).resolve()


class CanonicalStatus:
    """Probe the shipped canonical status helper against an immutable snapshot."""
    def __init__(self, trusted_root):
        self.helper = Path(trusted_root) / "scripts/phase-4b/heartbeat.sh"

    def __call__(self, record, deadline):
        # The helper reads the file several times. A private snapshot prevents
        # atomic writer replacements from mixing process instances during a probe.
        remaining = min(2, deadline - time.monotonic() - .25)
        if remaining <= 0:
            raise ClientError("deadline_exceeded")
        process, completed = None, False
        try:
            with tempfile.TemporaryDirectory(prefix="cockpit-heartbeat-") as directory:
                snapshot = Path(directory) / "record.json"
                snapshot.write_text(json.dumps(record), encoding="utf-8")
                process = subprocess.Popen(
                    ["bash", "-c", 'source "$1"; p4b_heartbeat_status "$2"',
                     "cockpit-status", str(self.helper), str(snapshot)],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    env={"PATH": os.defpath, "LC_ALL": "C"}, start_new_session=True)
                limit = time.monotonic() + remaining
                output = bytearray()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        wait = limit - time.monotonic()
                        if wait <= 0:
                            return "unknown"
                        if not selector.select(wait):
                            return "unknown"
                        chunk = os.read(process.stdout.fileno(), MAX_PROBE_BYTES + 1 - len(output))
                        if not chunk:
                            break
                        output.extend(chunk)
                        if len(output) > MAX_PROBE_BYTES:
                            return "unknown"
                result = bytes(output).decode("ascii").rstrip("\n")
                process.wait(timeout=max(.001, limit - time.monotonic()))
                completed = True
                return result if process.returncode == 0 and result in (*STAGES[-1:], "running", "crashed", "unknown") else "unknown"
        except (OSError, UnicodeError, ValueError, subprocess.SubprocessError):
            return "unknown"
        finally:
            if process is not None:
                if not completed:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except OSError:
                        try:
                            process.kill()
                        except OSError:
                            pass
                try:
                    process.wait(timeout=.2)
                except subprocess.TimeoutExpired:
                    pass
                process.stdout.close()


def normalize(record, filename, now):
    if (not isinstance(record, dict) or record.get("schema") != "p4b-heartbeat/v1"
            or not isinstance(record.get("run_id"), str) or not RUN_ID.fullmatch(record["run_id"])
            or filename != record["run_id"] + ".json" or record.get("stage") not in STAGES
            or not text(record.get("repo")) or not text(record.get("pr"), 20)
            or not re.fullmatch(r"[1-9][0-9]*", record["pr"])
            or not number(record.get("pid"), True) or not 1 <= record["pid"] <= 2147483647
            or "process_started_at" not in record
            or not (record["process_started_at"] is None or text(record["process_started_at"]))
            or not text(record.get("head"), 64) or not re.fullmatch(r"[0-9a-f]{7,64}", record["head"])
            or not text(record.get("reviewer")) or not text(record.get("direction"))
            or ("adapter" in record and not text(record["adapter"]))
            or type(record.get("summary_emitted")) is not bool or type(record.get("review_posted")) is not bool
            or type(record.get("dry_run")) is not bool):
        raise ValueError("invalid_heartbeat")
    transitions = record.get("stages")
    if not isinstance(transitions, list) or not 1 <= len(transitions) <= 4:
        raise ValueError("invalid_stages")
    reached = [item.get("stage") if isinstance(item, dict) else None for item in transitions]
    if (any(stage not in STAGES for stage in reached) or len(set(reached)) != len(reached)
            or sorted(reached, key=STAGES.index) != reached or reached[-1] != record["stage"]):
        raise ValueError("invalid_stages")
    row = {key: record[key] for key in ("run_id", "repo", "pr", "pid", "head", "stage", "reviewer", "direction", "dry_run", "summary_emitted", "review_posted")}
    row.update(id=record["repo"] + ":" + record["run_id"], provider=provider(record), reached=reached)
    for key in ("started_at_epoch", "stage_at_epoch", "adapter_started_at_epoch", "adapter_elapsed_seconds", "adapter_timeout_seconds", "adapter_exit_code", "exit_code", "token_count", "findings_count"):
        value = record.get(key)
        row[key] = value if number(value, True) else None
        if key.endswith("at_epoch") and row[key] is not None and row[key] > now:
            row[key] = None
    if row["adapter_timeout_seconds"] == 0:
        row["adapter_timeout_seconds"] = None
    for key in ("adapter_verdict", "verdict", "review_acknowledgment"):
        row[key] = record.get(key) if text(record.get(key)) else None
    if not row["summary_emitted"]:
        row.update(verdict=None, token_count=None, findings_count=None)
    row["posted_outcome"] = row["verdict"] if row["summary_emitted"] and row["review_posted"] and not row["dry_run"] else None
    return row


class LiveAgentsProvider:
    def __init__(self, inventory, heartbeat_dir, trusted_root, *, status=None, clock=time.time):
        self.repositories = frozenset(item.repo for item in inventory)
        self.directory = resolve_live_directory(str(heartbeat_dir))
        self.status = status or CanonicalStatus(trusted_root)
        self.clock = clock
        self._elapsed = {}

    def fetch(self, deadline):
        reader, selected, rows, terminals, diagnostics = LocalReader(deadline), [], [], [], []
        complete, seen, valid, probes = True, 0, 0, 0
        try:
            directory = reader.directory(self.directory)
        except OSError:
            raise ClientError("source_failed") from None
        try:
            # scandir(fd) avoids following/reopening the launch-owned path.
            with os.scandir(directory) as entries:
                for entry in entries:
                    reader.check()
                    seen += 1
                    if seen > MAX_SCAN:
                        complete = False
                        diagnostics.append("Heartbeat directory scan limit reached.")
                        break
                    if not entry.name.startswith("p4b-") or not entry.name.endswith(".json"):
                        continue
                    try:
                        # Inspect size before the shared reader's bounded read.
                        if entry.stat(follow_symlinks=False).st_size > MAX_RECORD_BYTES:
                            raise ValueError()
                        encoded = reader.read(directory, entry.name)
                        if len(encoded.encode("utf-8")) > MAX_RECORD_BYTES:
                            raise ValueError()
                        record = json.loads(encoded)
                        row = normalize(record, entry.name, self.clock())
                        if row["repo"] not in self.repositories:
                            continue
                        reader.check()
                        selected.append((row, record))
                        # Select within the scanned subset before spending process probes.
                        selected.sort(key=lambda item: (item[0]["stage"] == "done",
                                                       -(item[0]["stage_at_epoch"] or 0) if item[0]["stage"] == "done" else 0,
                                                       item[0]["id"]))
                        if len(selected) > MAX_RECORDS:
                            selected.pop()
                            complete = False
                            diagnostics.append("Heartbeat record limit reached.")
                        valid += 1
                    except (OSError, ValueError, UnicodeError, TypeError, OverflowError):
                        complete = False
                        if len(diagnostics) < 8:
                            diagnostics.append("A heartbeat record was malformed or refused; coverage is incomplete.")
        except OSError:
            raise ClientError("source_failed") from None
        finally:
            os.close(directory)
        for row, record in selected:
            reader.check()
            try:
                if row["stage"] == "done":
                    # Canonical terminal branch returns done before ps.
                    status = "done"
                elif probes < MAX_PROBES:
                    probes += 1
                    status = self.status(record, deadline)
                else:
                    status, complete = "unknown", False
                    diagnostics.append("Process probe limit reached; remaining process identities are unknown.")
                reader.check()
                row.update(process_status=status if status in ("running", "crashed", "unknown", "done") else "unknown", observed_at=self.clock())
                # A status seam never overrides the validated lifecycle.
                if row["stage"] == "done":
                    row["process_status"] = "done"
                    terminals.append(row)
                else:
                    if row["process_status"] == "done":
                        row["process_status"] = "unknown"
                    rows.append(row)
                identity = (row["id"], row["pid"], record["process_started_at"], row["head"], row["adapter_started_at_epoch"])
                seconds, observed = row["adapter_elapsed_seconds"], row["observed_at"]
                if "adapter" not in row["reached"]:
                    seconds = None
                elif row["stage"] == "adapter" and row["process_status"] == "running" and row["adapter_started_at_epoch"] is not None:
                    seconds = max(seconds or 0, row["observed_at"] - row["adapter_started_at_epoch"])
                if seconds is not None:
                    self._elapsed[identity] = (seconds, observed)
                else:
                    seconds, observed = self._elapsed.get(identity, (None, None))
                row.update(adapter_elapsed_observed_seconds=seconds, adapter_elapsed_observed_at=observed)
            except (OSError, ValueError, UnicodeError, TypeError, OverflowError):
                complete = False
                if len(diagnostics) < 8:
                    diagnostics.append("A heartbeat record was malformed or refused; coverage is incomplete.")
        now = self.clock()
        rows.sort(key=lambda row: row["id"])
        terminals.sort(key=lambda row: row["id"])
        current_ids = {row["id"] for row in (*rows, *terminals)}
        self._elapsed = {identity: value for identity, value in self._elapsed.items() if identity[0] in current_ids}
        # One current snapshot is the only memory scope, not permanent history.
        if len(self._elapsed) > MAX_RECORDS:
            self._elapsed = dict(list(self._elapsed.items())[-MAX_RECORDS:])
        return Sample({"schema": "cockpit-live-agents/v1", "live": rows, "terminal": terminals,
                       "observed_at": now, "hasObservations": bool(valid) or complete,
                       "coverage_complete": complete, "diagnostics": list(dict.fromkeys(diagnostics))}, hot=True)


def join_history(terminals, history):
    """Advisory exact-identity join; preserve history rows and every amount."""
    rows = copy.deepcopy(history)
    lookup = {(row.get("repo"), row.get("run_id")): row for row in rows if row.get("run_id")}
    unmatched, diagnostics = [], []
    for terminal in terminals:
        row = lookup.get((terminal["repo"], terminal["run_id"]))
        if row is None:
            unmatched.append(terminal["id"])
            continue
        compatible = all(row.get(key) in (None, terminal.get(other)) for key, other in
                         (("pr", "pr"), ("head_sha", "head"), ("reviewer", "reviewer"), ("started_at_epoch", "started_at_epoch")))
        if terminal["posted_outcome"] is not None and row.get("verdict") != terminal["posted_outcome"]:
            compatible = False
        row["heartbeat"] = {"compatible": compatible, "exit_code": terminal["exit_code"],
                            "summary_emitted": terminal["summary_emitted"], "review_posted": terminal["review_posted"],
                            "review_acknowledgment": terminal["review_acknowledgment"], "observed_at": terminal["observed_at"]}
        if not compatible:
            diagnostics.append("Conflicting terminal/history observations share a genuine run ID.")
    return {"history": rows, "unmatched": unmatched, "diagnostics": list(dict.fromkeys(diagnostics))}
