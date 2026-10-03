"""Bounded read-only Phase 4b history; accounting remains owned by its helper."""

import collections
import copy
import datetime as dt
import json
import math
import os
import re
import stat
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

from .github import ClientError
from .scheduler import Sample

RUN_ID = re.compile(r"p4b-[A-Za-z0-9._-]{1,200}\Z")
SAFE = 2**53 - 1
SEVERITIES = ("P0", "P1", "P2", "P3", "nitpick", "unknown")
TOKEN_FIELDS = ("total", "input", "output", "cache_creation", "cache_read", "reasoning")
MAX_FILE = 2 * 1024 * 1024
MAX_BYTES = 32 * 1024 * 1024
MAX_FILES = 512
MAX_ROWS = 10000


def number(value, integer=False):
    return (type(value) in (int, float) and math.isfinite(value) and 0 <= value <= SAFE
            and (not integer or type(value) is int))


def text(value, limit=240):
    return isinstance(value, str) and 0 < len(value) <= limit and not any(ord(c) < 32 for c in value)


def provider(loop):
    # Same precedence and case behavior as p4b_acct_loop_provider.
    rev, adapter, direction = loop.get("reviewer", "").lower(), loop.get("adapter", ""), loop.get("direction", "")
    return next((name for name in ("codex", "claude") if name in rev or name in adapter or "->" + name in direction), "other")


@dataclass(frozen=True)
class Checkout:
    repo: str
    path: Path


def discover_checkouts(root, repo, *, run=subprocess.run, deadline=None):
    """Trusted launch configuration only; browser input never supplies roots."""
    timeout = max(.01, min(5, (deadline or time.monotonic() + 5) - time.monotonic()))
    env = {"PATH": os.defpath, "HOME": str(Path.home()), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    try:
        result = run(["git", "-C", str(root), "worktree", "list", "--porcelain"],
                     capture_output=True, text=True, check=True, timeout=timeout, env=env)
        if len(result.stdout) > 128000:
            raise ValueError()
        paths = [Path(line[9:]) for line in result.stdout.splitlines() if line.startswith("worktree ")]
        if not paths or len(paths) > 64:
            raise ValueError()
        return tuple(Checkout(repo, path) for path in dict.fromkeys(paths))
    except (OSError, ValueError, subprocess.SubprocessError):
        raise ClientError("source_failed") from None


class LocalReader:
    """openat + O_NOFOLLOW for every component; no symlink/FIFO/device reads."""
    def __init__(self, deadline):
        self.deadline, self.bytes, self.files = deadline, 0, 0

    def check(self):
        if time.monotonic() >= self.deadline:
            raise ClientError("deadline_exceeded")

    def directory(self, path):
        path = Path(os.path.abspath(path))
        fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                self.check()
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            return fd
        except BaseException:
            os.close(fd)
            raise

    def read(self, directory, name):
        self.check()
        self.files += 1
        if self.files > MAX_FILES:
            raise ValueError("file_limit")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            size = os.fstat(fd)
            if not stat.S_ISREG(size.st_mode) or size.st_size > MAX_FILE:
                raise ValueError("file_refused")
            chunks, count = [], 0
            while True:
                self.check()
                chunk = os.read(fd, min(65536, MAX_FILE + 1 - count))
                if not chunk:
                    break
                count += len(chunk)
                self.bytes += len(chunk)
                if count > MAX_FILE or self.bytes > MAX_BYTES:
                    raise ValueError("byte_limit")
                chunks.append(chunk)
            return b"".join(chunks).decode("utf-8")
        finally:
            os.close(fd)


def resolve_history_settings(settings, inventory, root):
    """Resolve operator-owned launch JSON once; never accept browser paths."""
    if not isinstance(settings, dict) or set(settings) - {"checkouts", "price_keys"}:
        raise ValueError("invalid_history_settings")
    inventory = tuple(inventory)
    repositories = {item.repo for item in inventory}
    hubs = [item.repo for item in inventory if item.hub]
    configured, keys = settings.get("checkouts", {}), settings.get("price_keys", {})
    if (len(hubs) != 1 or not isinstance(configured, dict) or not isinstance(keys, dict)
            or set(configured) - repositories or set(keys) - {"claude", "codex"}
            or any(not text(key) for key in keys.values())):
        raise ValueError("invalid_history_settings")
    root = Path(root).resolve()
    requested = [(hubs[0], root)]
    for repo, paths in configured.items():
        if not isinstance(paths, list) or not paths or len(paths) > 64:
            raise ValueError("invalid_history_settings")
        for path in paths:
            if not text(path, 4096) or not Path(path).is_absolute():
                raise ValueError("invalid_history_settings")
            resolved = Path(path).resolve()
            if not resolved.is_dir():
                raise ValueError("invalid_history_settings")
            requested.append((repo, resolved))
    requested = tuple(dict.fromkeys(requested))
    if len(requested) > 64:
        raise ValueError("invalid_history_settings")
    deadline = time.monotonic() + 5
    if keys:
        reader = LocalReader(deadline)
        directory = reader.directory(root / "scripts/phase-4b")
        try:
            prices = json.loads(reader.read(directory, "prices.json"))
        finally:
            os.close(directory)
        for name, key in keys.items():
            if not isinstance(prices, dict) or not isinstance(prices.get("providers"), dict):
                raise ValueError("invalid_history_settings")
            source = "anthropic" if name == "claude" else "openai"
            source_prices = prices["providers"].get(source)
            if not isinstance(source_prices, dict) or not isinstance(source_prices.get("models"), dict):
                raise ValueError("invalid_history_settings")
            models = source_prices["models"]
            allowed = {f"{source}.{model}.{tier}" for model, tiers in models.items() if isinstance(tiers, dict)
                       for tier, rates in tiers.items() if isinstance(rates, dict) and number(rates.get("input")) and number(rates.get("output"))}
            if key not in allowed:
                raise ValueError("invalid_history_settings")
    checkouts, owners = {}, {}
    for repo, path in requested:
        if time.monotonic() >= deadline:
            raise ClientError("deadline_exceeded")
        found = (Checkout(repo, path), *discover_checkouts(path, repo, deadline=deadline))
        for checkout in found:
            if not checkout.path.is_absolute():
                raise ValueError("invalid_history_settings")
            resolved = checkout.path.resolve()
            if resolved in owners and owners[resolved] != repo:
                raise ValueError("invalid_history_settings")
            owners[resolved] = repo
            checkouts[(repo, resolved)] = Checkout(repo, resolved)
            if len(checkouts) > 64:
                raise ValueError("invalid_history_settings")
    return tuple(checkouts.values()), MappingProxyType(dict(keys))


def normalize_loop(loop):
    if (not isinstance(loop, dict) or not isinstance(loop.get("tokens"), dict)
            or not isinstance(loop.get("findings", {}), dict)
            or not isinstance(loop.get("fail_closed", {}), dict)):
        raise ValueError("invalid_loop")
    required = {"loop", "reviewer", "adapter", "direction", "head_sha", "verdict", "posted", "elapsed_seconds", "tokens", "findings", "fail_closed"}
    if (not required.issubset(loop) or not set((*TOKEN_FIELDS, "cost_usd", "source")).issubset(loop["tokens"])
            or not set(SEVERITIES).issubset(loop["findings"]) or type(loop["fail_closed"].get("happened")) is not bool
            or not number(loop.get("loop"), True) or loop["loop"] < 1
            or loop.get("posted") not in ("posted", "dry-run", "direct-probe", "not-posted")):
        raise ValueError("invalid_loop")
    out = {}
    for key in ("reviewer", "adapter", "direction", "head_sha", "verdict", "posted"):
        if not text(loop.get(key)):
            raise ValueError("invalid_loop")
        out[key] = loop[key]
    if loop["verdict"] not in ("APPROVED", "APPROVED_WITH_ADVISORIES", "CHANGES_REQUESTED", "UNAVAILABLE"):
        raise ValueError("invalid_verdict")
    for key in ("loop", "elapsed_seconds", "timeout_seconds", "started_at_epoch"):
        value = loop.get(key)
        if value is not None and not number(value, True):
            raise ValueError("invalid_number")
        if key == "started_at_epoch" and value is not None and value >= 253402300800:
            raise ValueError("invalid_time")
        out[key] = value
    run_id = loop.get("run_id")
    if run_id is not None and (not isinstance(run_id, str) or not RUN_ID.fullmatch(run_id)):
        raise ValueError("invalid_run_id")
    out["run_id"] = run_id
    out["tokens"] = {}
    for key in (*TOKEN_FIELDS, "cost_usd"):
        value = loop["tokens"].get(key)
        if value is not None and not number(value, key != "cost_usd"):
            raise ValueError("invalid_tokens")
        out["tokens"][key] = value
    source = loop["tokens"].get("source", "unavailable")
    out["tokens"]["source"] = source if text(source) else "unavailable"
    # Older split-only records follow the canonical helper's exact derivation.
    if out["tokens"]["total"] is None and all(out["tokens"][key] is not None for key in ("input", "output")):
        total = out["tokens"]["input"] + out["tokens"]["output"]
        if total > SAFE:
            raise ValueError("invalid_tokens")
        out["tokens"]["total"] = total
    out["findings"] = {}
    for key in SEVERITIES:
        value = loop.get("findings", {}).get(key)
        if value is not None and not number(value, True):
            raise ValueError("invalid_findings")
        out["findings"][key] = value
    out["fail_closed"] = {"happened": loop.get("fail_closed", {}).get("happened") is True}
    out["provider"] = provider(out)
    # Codex totals never become an invented split, even if an edited local file claims one.
    if out["provider"] == "codex":
        for key in TOKEN_FIELDS[1:]:
            out["tokens"][key] = None
    return out


class Accounting:
    def __init__(self, root):
        self.root = Path(root)

    def totals(self, groups, deadline):
        """Reuse canonical compute_totals, with no gh/op/model calls or ambient secrets."""
        script = 'source "$1"; while IFS= read -r loops; do p4b_acct_compute_totals "$loops" "" null || exit 1; done'
        env = {"PATH": "/opt/homebrew/bin:/usr/local/bin:" + os.defpath, "HOME": str(Path.home()), "LC_ALL": "C"}
        try:
            result = subprocess.run(["bash", "-c", script, "cockpit-accounting", str(self.root / "scripts/phase-4b/accounting.sh")],
                                    input="\n".join(json.dumps(group) for group in groups) + "\n", capture_output=True,
                                    text=True, timeout=max(.01, deadline - time.monotonic()), check=True, env=env)
            if len(result.stdout) > 2 * 1024 * 1024:
                raise ValueError()
            values = [json.loads(line) for line in result.stdout.splitlines()]
            if len(values) != len(groups):
                raise ValueError()
            def safe(value):
                if isinstance(value, dict):
                    return all(safe(item) for item in value.values())
                if isinstance(value, list):
                    return all(safe(item) for item in value)
                return not isinstance(value, (int, float)) or isinstance(value, bool) or number(value)
            if not all(safe(value) for value in values):
                raise ValueError()
            return values
        except (OSError, ValueError, subprocess.SubprocessError):
            raise ClientError("source_failed") from None


def cost_for(loop, prices, keys):
    tokens = loop["tokens"]
    if tokens["cost_usd"] is not None:
        return {"kind": "reported", "usd": tokens["cost_usd"], "low_usd": None, "high_usd": None,
                "source": tokens["source"], "price_key": None, "price_version": None}
    key = keys.get(loop["provider"])
    version = prices.get("version") if isinstance(prices, dict) and text(prices.get("version"), 64) else None
    unavailable = {"kind": "unavailable", "usd": None, "low_usd": None, "high_usd": None,
                   "source": "prices.json · no applicable measured pricing", "price_key": key, "price_version": version}
    if not key:
        return unavailable
    parts = key.split(".")
    if len(parts) < 3:
        return unavailable
    rates = prices
    for part in ("providers", parts[0], "models", ".".join(parts[1:-1]), parts[-1]):
        rates = rates.get(part, {}) if isinstance(rates, dict) else {}
    if not isinstance(rates, dict):
        rates = {}
    if tokens["input"] is not None and tokens["output"] is not None:
        fields = [("input", "input"), ("output", "output"), ("cache_creation", "cache_write_5m"), ("cache_read", "cache_read")]
        if any(not number(rates.get(rate)) for token, rate in fields if tokens[token] is not None):
            return unavailable
        value = sum(tokens[token] * rates[rate] / 1e6 for token, rate in fields if tokens[token] is not None)
        return {**unavailable, "kind": "estimated", "usd": value, "source": "prices.json · measured split · configured price key"}
    if tokens["total"] is not None and number(rates.get("input")) and number(rates.get("output")):
        known_rates = [rates[field] for field in ("input", "output", "cached_input") if number(rates.get(field))]
        return {**unavailable, "kind": "bounded_estimate", "low_usd": min(known_rates) * tokens["total"] / 1e6,
                "high_usd": max(known_rates) * tokens["total"] / 1e6,
                "source": "prices.json · total-only bound · configured price key · split unavailable"}
    return unavailable


class AgentsProvider:
    def __init__(self, inventory, checkouts, trusted_root, *, price_keys=None, github=None, reviewers=("nathanpayne-codex", "nathanpayne-claude"), clock=time.time):
        self.repositories = {item.repo for item in inventory}
        self.checkouts = tuple(dict.fromkeys(Checkout(item.repo, Path(item.path).resolve()) for item in checkouts))
        if not self.checkouts or len(self.checkouts) > 64 or any(item.repo not in self.repositories for item in self.checkouts):
            raise ValueError("invalid_checkouts")
        self.root, self.clock = Path(trusted_root).resolve(), clock
        self.accounting, self.price_keys = Accounting(self.root), dict(price_keys or {})
        if any(key not in ("codex", "claude", "other") or not text(value) for key, value in self.price_keys.items()):
            raise ValueError("invalid_price_keys")
        self.github, self.reviewers = github, frozenset(reviewers)
        self._review_cache = {}

    def fetch(self, deadline):
        reader = LocalReader(deadline)
        rows, approvals, diagnostics = [], [], []
        observed_checkouts = 0
        for root_no, checkout in enumerate(self.checkouts):
            log_rows, ledger_rows = [], []
            try:
                root_fd = reader.directory(checkout.path)
                os.close(root_fd)
            except OSError:
                diagnostics.append("A configured checkout is missing, unreadable or refused.")
                continue
            try:
                state = reader.directory(checkout.path / ".mergepath")
            except FileNotFoundError:
                observed_checkouts += 1  # Accessible checkout before its first run.
                continue
            except OSError:
                diagnostics.append("A configured checkout state directory is unreadable or refused.")
                continue
            scan_complete, readable_telemetry = True, False
            try:
                sources = [(state, "phase-4b-ledger.jsonl", "ledger")]
                try:
                    logs = os.open("phase-4b-loops", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=state)
                except FileNotFoundError:
                    logs = None
                except OSError:
                    logs = None
                    scan_complete = False
                    diagnostics.append("A checkout loop directory is unreadable or refused.")
                try:
                    if logs is not None:
                        names = sorted(os.listdir(logs))
                        if len(names) > MAX_FILES:
                            raise ValueError("file_limit")
                        sources += [(logs, name, "loop") for name in names if name.endswith((".jsonl", ".jsonl.archive"))]
                    for fd, name, kind in sources:
                        try:
                            content = reader.read(fd, name)
                        except FileNotFoundError:
                            continue
                        except (OSError, ValueError, UnicodeError):
                            scan_complete = False
                            diagnostics.append("A local accounting file is unreadable, oversized or refused.")
                            continue
                        readable_telemetry = True
                        for line_no, line in enumerate(content.splitlines(), 1):
                            if not line.strip():
                                continue
                            if len(rows) + len(log_rows) + len(ledger_rows) >= MAX_ROWS:
                                raise ValueError("row_limit")
                            try:
                                record = json.loads(line)
                                repo, pr = checkout.repo, None
                                if kind == "loop":
                                    if record.get("schema") != "p4b-loop-log/v1":
                                        raise ValueError()
                                    candidates = [r for r in self.repositories if name.startswith(r.replace("/", "-") + "-pr")]
                                    if len(candidates) != 1:
                                        raise ValueError()
                                    repo = candidates[0]
                                    match = re.search(r"-pr([1-9][0-9]*)(?:\.|-)", name)
                                    if not match:
                                        raise ValueError()
                                    pr = match[1]
                                    loop = dict(record["loop"])
                                    if loop.get("started_at_epoch") is None:
                                        loop["started_at_epoch"] = record.get("started_at_epoch")
                                    entries = [loop]
                                else:
                                    if record.get("schema") != "p4b-accounting/v1" or not number(record.get("pr"), True) or record["pr"] < 1:
                                        raise ValueError()
                                    repo = None
                                    pr, entries = str(record["pr"]), record["loops"]
                                    if not isinstance(entries, list) or len(entries) > MAX_ROWS:
                                        raise ValueError()
                                    approval_rows = []
                                    approvals.append({"repo": None, "pr": pr, "loops": copy.deepcopy(entries), "observations": approval_rows, "totals": record.get("totals"), "source": f"checkout-{root_no + 1}:ledger:{line_no}"})
                                for index, entry in enumerate(entries):
                                    if len(rows) + len(log_rows) + len(ledger_rows) >= MAX_ROWS:
                                        raise ValueError("row_limit")
                                    normalized = normalize_loop(entry)
                                    normalized.update(repo=repo, pr=pr, id=f"local-{root_no + 1}-{kind}-{name}-{line_no}-{index}",
                                                      identity="run_id" if normalized["run_id"] else "legacy_locator",
                                                      sources=[f"checkout-{root_no + 1}:{kind}:{line_no}:{index}"], conflict=False)
                                    (log_rows if kind == "loop" else ledger_rows).append(normalized)
                                    if kind == "ledger":
                                        approval_rows.append(normalized)
                            except (ValueError, KeyError, TypeError, AttributeError):
                                scan_complete = False
                                diagnostics.append("An accounting record is malformed or has an unknown repository.")
                finally:
                    if logs is not None:
                        os.close(logs)
            finally:
                os.close(state)
            if scan_complete or readable_telemetry:
                observed_checkouts += 1
            # A trusted hub checkout may review consumers. Ledger records have no repo.
            # Only local run/PR evidence establishes a target; location never does.
            target_ids, target_legacy = collections.defaultdict(set), collections.defaultdict(set)
            for row in log_rows:
                if row["run_id"]:
                    target_ids[(row["run_id"], row["pr"])].add(row["repo"])
                else:
                    target_legacy[self._signature(row, attribution=True)].add(row["repo"])
            for row in ledger_rows:
                repos = target_ids[(row["run_id"], row["pr"])] if row["run_id"] else target_legacy[self._signature(row, attribution=True)]
                if len(repos) == 1:
                    row["repo"] = next(iter(repos))
            # Approval loops cross-check actual log occurrences in this checkout only.
            signatures = collections.Counter(self._signature(row) for row in log_rows if not row["run_id"])
            for row in ledger_rows:
                signature = self._signature(row)
                if not row["run_id"] and signatures[signature] > 0:
                    signatures[signature] -= 1
                else:
                    log_rows.append(row)
            rows.extend(log_rows)
        # New ledger identities may be attributed by a unique genuine ID+PR in another root.
        target_ids = collections.defaultdict(set)
        for row in rows:
            if row["repo"] is not None and row["run_id"]:
                target_ids[(row["run_id"], row["pr"])].add(row["repo"])
        for row in rows:
            if row["repo"] is None and row["run_id"]:
                repos = target_ids[(row["run_id"], row["pr"])]
                if len(repos) == 1:
                    row["repo"] = next(iter(repos))
        for approval in approvals:
            repos = {row["repo"] for row in approval["observations"]}
            approval["repo"] = next(iter(repos)) if len(repos) == 1 else None
        deduped = {}
        for row in rows:
            identity = (row["repo"], row["run_id"]) if row["run_id"] else (row["id"],)
            if identity not in deduped:
                if row["run_id"]:
                    row["id"] = (row["repo"] or "unknown-target") + ":" + row["run_id"]
                deduped[identity] = row
            else:
                current = deduped[identity]
                current["sources"].extend(row["sources"])
                mismatched = [key for key in ("pr", "reviewer", "head_sha", "verdict", "tokens", "findings", "elapsed_seconds")
                              if current[key] != row[key] and current[key] is not None and row[key] is not None]
                if mismatched:
                    current["conflict"] = True
                    current["tokens"] = {key: None for key in (*TOKEN_FIELDS, "cost_usd")}
                    current["tokens"]["source"] = "conflicting_observations"
                    current["elapsed_seconds"] = None
                    diagnostics.append("Conflicting observations share a genuine run_id; amounts are unavailable.")
                if row["posted"] != "not-posted":
                    current["posted"] = row["posted"]
        rows = list(deduped.values())
        try:
            pricing_fd = reader.directory(self.root / "scripts/phase-4b")
            try:
                prices = json.loads(reader.read(pricing_fd, "prices.json"))
            finally:
                os.close(pricing_fd)
        except (OSError, ValueError, UnicodeError):
            prices = {}
            diagnostics.append("Versioned price table unavailable.")
        for row in rows:
            row["cost"] = cost_for(row, prices, self.price_keys)
            epoch = row["started_at_epoch"]
            row["day"] = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).date().isoformat() if epoch is not None and epoch < 253402300800 else None
        pr_groups = collections.defaultdict(list)
        for row in rows:
            pr_groups[(row["repo"], row["pr"])].append(row)
        if len(pr_groups) > 128 or len(approvals) > 256:
            raise ClientError("source_failed")
        groups = [rows] + [record["loops"] for record in approvals] + list(pr_groups.values())
        totals = self.accounting.totals(groups, deadline)
        per_pr = [{"repo": repo, "pr": pr, "totals": total} for (repo, pr), total in zip(pr_groups, totals[1 + len(approvals):])]
        for record, actual in zip(approvals, totals[1:]):
            reported = record["totals"]
            if not isinstance(reported, dict) or any(reported.get(key) != actual.get(key) for key in ("adapter_invocations", "tokens_total", "elapsed_seconds_total", "tokens_by_provider", "fail_closed_events", "reported_cost_usd")):
                diagnostics.append("An approval accounting block disagrees with canonical loop totals.")
        rows.sort(key=lambda row: (row["started_at_epoch"] or 0, row["id"]), reverse=True)
        crosscheck = self._review_crosscheck(rows, deadline)
        return Sample({"schema": "cockpit-agents/v1", "history": rows, "canonical_totals": totals[0], "per_pr": per_pr,
                       "coverage": {"checkouts": len(self.checkouts), "legacy_runs": sum(row["run_id"] is None for row in rows),
                                    "tokens_measured": sum(row["tokens"]["total"] is not None for row in rows), "runs": len(rows), "unattributed_runs": sum(row["repo"] is None for row in rows)},
                       "diagnostics": list(dict.fromkeys(diagnostics)), "history_complete": not diagnostics,
                       "hasObservations": observed_checkouts > 0, "observed_checkouts": observed_checkouts,
                       "review_crosscheck": crosscheck,
                       "live": None}, hot=False)

    def _review_crosscheck(self, rows, deadline):
        if self.github is None:
            return {"status": "unavailable", "checked_prs": 0, "truncated": False,
                    "diagnostics": ["Approved-review cross-check is not connected."]}
        prs = list(dict.fromkeys((row["repo"], row["pr"]) for row in rows if row["repo"] is not None))
        diagnostics, checked = [], 0
        selected = prs[:8]
        for repo, pr in selected:
            cached = self._review_cache.get((repo, pr))
            if cached and self.clock() - cached["at"] < 1800:
                result = cached["result"]
            else:
                try:
                    reviews = self.github.pages(f"/repos/{repo}/pulls/{pr}/reviews?per_page=100", max_pages=5, deadline=deadline)
                    records = []
                    for review in reviews:
                        if (not isinstance(review, dict) or review.get("state") != "APPROVED"
                                or review.get("user", {}).get("login") not in self.reviewers):
                            continue
                        body = review.get("body")
                        if not isinstance(body, str):
                            continue
                        for match in re.finditer(r"<!--\s*p4b-accounting:v1\s+(.*?)-->", body, re.S):
                            record = json.loads(match[1])
                            if (not isinstance(record, dict) or record.get("schema") != "p4b-accounting/v1"
                                    or str(record.get("pr")) != pr or not isinstance(record.get("loops"), list)):
                                raise ValueError()
                            if not record["loops"] or len(record["loops"]) > MAX_ROWS or len(records) >= 500:
                                raise ValueError()
                            # Arithmetic is deliberately performed on the original
                            # canonical block, after its loops pass schema validation.
                            for loop in record["loops"]:
                                normalize_loop(loop)
                            records.append(record)
                    totals = self.accounting.totals([record["loops"] for record in records], deadline) if records else []
                    bad = any(not isinstance(record.get("totals"), dict) or any(record["totals"].get(key) != total.get(key)
                              for key in ("adapter_invocations", "tokens_total", "elapsed_seconds_total", "tokens_by_provider", "reported_cost_usd", "fail_closed_events"))
                              for record, total in zip(records, totals))
                    result = ({"status": "mismatch" if bad else "checked", "records": len(records)} if records
                              else {"status": "unavailable", "error": "no_evidence", "records": 0})
                except ClientError as exc:
                    result = {"status": "unavailable", "error": exc.category}
                except (ValueError, TypeError, AttributeError):
                    result = {"status": "unavailable", "error": "invalid_response"}
                self._review_cache[(repo, pr)] = {"at": self.clock(), "result": result}
            if result["status"] == "checked":
                checked += 1
            elif result["status"] == "mismatch":
                diagnostics.append(f"{repo} #{pr}: approved-review accounting disagrees with canonical totals.")
            else:
                diagnostics.append(f"{repo} #{pr}: approved-review cross-check unavailable ({result['error']}).")
        # Retain only bounded selected PR state; no persistent review-body cache.
        self._review_cache = {key: value for key, value in self._review_cache.items() if key in selected}
        return {"status": "partial" if diagnostics or len(prs) > 8 else "checked", "checked_prs": checked,
                "observations": [{"repo": repo, "pr": pr, "observed_at": self._review_cache[(repo, pr)]["at"], **self._review_cache[(repo, pr)]["result"]} for repo, pr in selected],
                "truncated": len(prs) > 8, "diagnostics": diagnostics}

    @staticmethod
    def _signature(row, attribution=False):
        excluded = {"id", "identity", "sources", "conflict", "started_at_epoch"}
        if attribution:
            excluded.add("repo")
        return json.dumps({key: value for key, value in row.items() if key not in excluded}, sort_keys=True)
