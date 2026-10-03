"""Read-only Actions observations; unavailable inputs never become estimates."""

import copy
import datetime as dt
import math
import re
import time
from decimal import Decimal, InvalidOperation

from .github import ClientError
from .inventory import REPO
from .scheduler import Sample

SAFE = 2 ** 53 - 1
INSTALLATION = "api rate limit exceeded for installation"


def number(value, maximum=SAFE):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= maximum


def count(value):
    return type(value) is int and 0 <= value <= SAFE


def unavailable(reason, last=None):
    value = copy.deepcopy(last) if last else {"observed_at": None}
    value.update(available=False, stale=True, error=reason)
    return value


def billing_usage(payload, owner, now):
    """The REST field is netAmount; CSV net_amount is not a REST fallback."""
    rows = payload.get("usageItems") if type(payload) is dict else None
    if type(rows) is not list or len(rows) > 20000:
        raise ClientError("invalid_page")
    total, repositories = Decimal(0), {}
    unattributed = Decimal(0)
    for row in rows:
        if type(row) is not dict or type(row.get("product")) is not str:
            raise ClientError("invalid_page")
        if row["product"].casefold() != "actions":
            continue
        value = row.get("netAmount")
        # No coercion of strings, booleans, null, infinity, negative values.
        if not number(value, 10 ** 9):
            raise ClientError("invalid_page")
        try:
            amount = Decimal(str(value))
        except InvalidOperation:
            raise ClientError("invalid_page") from None
        total += amount
        if total > 10 ** 9:
            raise ClientError("invalid_page")
        repo = row.get("repositoryName")
        if repo in (None, ""):
            unattributed += amount
        elif type(repo) is str and re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", repo):
            key = owner + "/" + repo
            repositories[key] = repositories.get(key, Decimal(0)) + amount
        else:
            raise ClientError("invalid_page")
    return {"available": True, "stale": False, "error": None, "observed_at": now,
            "net_amount": float(total), "unattributed": float(unattributed),
            "repositories": [{"repo": key, "net_amount": float(value)} for key, value in
                             sorted(repositories.items(), key=lambda item: (-item[1], item[0]))],
            "workflow_attribution": "unavailable", "kind": "reported"}


def measured_coefficient(value, repo, now):
    """Explicit measurements expire; neither design figures nor defaults qualify."""
    if type(value) is not dict or value.get("repo") != repo:
        return None
    requests, runs = value.get("requests"), value.get("runs")
    start, end, observed = (value.get(key) for key in ("window_start", "window_end", "observed_at"))
    provenance = value.get("provenance")
    if (not count(requests) or requests > 10 ** 7 or not count(runs) or not 1 <= runs <= 10 ** 6
            or not all(number(x) for x in (start, end, observed))
            or not 0 < end - start <= 86400 or not end <= observed <= now
            or now - observed > 3600 or type(provenance) is not str
            or not 1 <= len(provenance.strip()) <= 240 or any(ord(c) < 32 for c in provenance)):
        return None
    return {"requests_per_run": requests / runs, "observed_at": observed,
            "window_start": start, "window_end": end, "provenance": provenance}


def run_rows(rows, repo, now, status=None):
    if type(rows) is not list or len(rows) > 10000:
        raise ClientError("invalid_page")
    result, seen = [], set()
    for row in rows:
        if type(row) is not dict or not count(row.get("id")) or row["id"] == 0:
            raise ClientError("invalid_page")
        if row["id"] in seen:
            continue
        seen.add(row["id"])
        if type(row.get("repository")) is dict and row["repository"].get("full_name") != repo:
            raise ClientError("invalid_page")
        if status and row.get("status") != status:
            raise ClientError("invalid_page")
        created = row.get("created_at")
        try:
            timestamp = dt.datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp()
        except (AttributeError, TypeError, ValueError, OverflowError):
            raise ClientError("invalid_page") from None
        if not number(timestamp) or timestamp > now + 60:
            raise ClientError("invalid_page")
        message = row.get("failure_message")
        # Only a failed run's explicit message can establish this condition.
        hard = (row.get("conclusion") == "failure" and type(message) is str
                and len(message) <= 4000 and INSTALLATION in message.casefold()
                and now - 3600 <= timestamp <= now)
        result.append({"id": str(row["id"]), "created_at": timestamp, "installation_exhausted": hard})
    return result


def ci_observation(envelope, repo, now):
    """Read a copied ci/v1 snapshot without causing a poll or log request."""
    data = envelope.get("data") if type(envelope) is dict else None
    if (type(data) is not dict or data.get("schema") != "ci/v1"
            or envelope.get("stale") is not False or not count(data.get("recent_seconds"))
            or data["recent_seconds"] < 3600):
        return None
    observations = data.get("repositories")
    if type(observations) is not list:
        return None
    observation = next((row for row in observations if type(row) is dict and row.get("repo") == repo), None)
    if (not observation or observation.get("stale") is not False or observation.get("error") is not None
            or not number(observation.get("observed_at"))
            or not 0 <= now - observation["observed_at"] <= 120):
        return None
    raw = data.get("runs")
    if type(raw) is not list or len(raw) > 20000:
        return None
    queued, running, hour, seen = [], [], [], set()
    for row in raw:
        if type(row) is not dict or row.get("repo") != repo:
            continue
        identity, created = row.get("id"), row.get("created_at")
        if (type(identity) is not str or not re.fullmatch(r"[1-9][0-9]{0,15}", identity)
                or int(identity) > SAFE or not number(created)):
            return None
        if identity in seen:
            continue
        seen.add(identity)
        message = ""
        checks = row.get("checks", [])
        if type(checks) is not list:
            return None
        if row.get("conclusion") == "failure":
            for check in checks:
                if (type(check) is dict and check.get("conclusion") == "failure"
                        and type(check.get("diagnostic")) is str
                        and len(check["diagnostic"]) <= 4000
                        and INSTALLATION in check["diagnostic"].casefold()):
                    message = INSTALLATION
        normalized = {"id": int(identity), "created_at": dt.datetime.fromtimestamp(created, dt.timezone.utc).isoformat(),
                      "status": row.get("status"), "conclusion": row.get("conclusion"), "failure_message": message}
        if row.get("status") == "queued":
            queued.append(normalized)
        if row.get("status") == "in_progress":
            running.append(normalized.copy())
        if now - 3600 <= created <= now:
            hour.append(normalized.copy())
    return {"complete": True, "stale": False, "observed_at": observation["observed_at"],
            "queued": queued, "running": running, "hour": hour}


class ActionsProvider:
    def __init__(self, client, inventory, *, settings=None, ci_snapshot=None,
                 robot_snapshot=None, clock=time.time, monotonic=time.monotonic):
        self.client, self.clock, self.monotonic = client, clock, monotonic
        self.repos = tuple(item.repo for item in inventory)
        if not self.repos or len(self.repos) > 100 or any(not REPO.fullmatch(repo) for repo in self.repos):
            raise ValueError("invalid_actions_inventory")
        self.settings = copy.deepcopy(settings) if type(settings) is dict else {}
        self.ci_snapshot, self.robot_snapshot = ci_snapshot, robot_snapshot
        self._billing, self._billing_due, self._billing_period = None, 0, None
        self._last, self._jam, self._cursor = {}, {}, 0
        self._robot_last = None

    def _billing_read(self, deadline, now):
        current = dt.datetime.fromtimestamp(now, dt.timezone.utc)
        period = (current.year, current.month)
        if now < self._billing_due and self._billing is not None and self._billing_period == period:
            return copy.deepcopy(self._billing)
        # A new report period is due immediately, including after a cached denial.
        # Remember the attempted period separately from retained last-good data.
        self._billing_due, self._billing_period = now + 1800, period
        owner = self.settings.get("billing_owner", self.repos[0].split("/")[0])
        if type(owner) is not str or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", owner):
            return unavailable("source_failed")
        try:
            payload = self.client.get(f"/users/{owner}/settings/billing/usage?year={current.year}&month={current.month}", deadline=deadline)
            value = billing_usage(payload, owner, now)
            value["year"], value["month"] = current.year, current.month
            self._billing = value
        except ClientError as exc:
            self._billing = unavailable(exc.category, self._billing)
        except Exception:
            self._billing = unavailable("source_failed", self._billing)
        return copy.deepcopy(self._billing)

    def _repo_read(self, repo, deadline, now):
        # An injected snapshot must certify complete queue and hour coverage.
        if self.ci_snapshot is not None:
            value = self.ci_snapshot(repo, now)
            if (type(value) is not dict or value.get("complete") is not True
                    or value.get("stale") is not False or not number(value.get("observed_at"))
                    or not 0 <= now - value["observed_at"] <= 120):
                raise ClientError("source_failed")
            queued = run_rows(value.get("queued"), repo, now, "queued")
            running = run_rows(value.get("running"), repo, now, "in_progress")
            hour = run_rows(value.get("hour"), repo, now)
            observed = value["observed_at"]
        else:
            def read(query, status=None):
                rows = self.client.pages(f"/repos/{repo}/actions/runs?{query}&per_page=100", collection="workflow_runs", max_pages=10, deadline=deadline)
                return run_rows(rows, repo, now, status)
            queued = read("status=queued", "queued")
            running = read("status=in_progress", "in_progress")
            start = dt.datetime.fromtimestamp(now - 3600, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            hour = read("created=%3E%3D" + start)
            observed = now
        volume = sum(now - 3600 <= row["created_at"] <= now for row in hour)
        hard = [row["id"] for row in hour if row["installation_exhausted"]]
        q, r = len(queued), len(running)
        previous = self._jam.get(repo)
        qualifies = q >= 40 and r <= 1
        # Repeated snapshots, gaps, clock reversals and failed reads cannot age a jam.
        comparable = previous is not None and 0 < observed - previous["last"] <= 120
        repeated = previous is not None and observed == previous["last"]
        since = previous["since"] if qualifies and (comparable or repeated) else observed
        self._jam[repo] = {"since": since, "last": observed} if qualifies else None
        # A repeated observation retains its proven interval, never wall-clock age.
        jammed = qualifies and (comparable or repeated) and observed - since > 1800
        measurements = self.settings.get("measurements")
        coefficient = measured_coefficient(measurements.get(repo) if type(measurements) is dict else None, repo, now)
        estimate = volume * coefficient["requests_per_run"] if coefficient else None
        if estimate is not None and not number(estimate):
            estimate, coefficient = None, None
        return {"repo": repo, "available": True, "stale": False, "error": None,
                "observed_at": observed, "queued": q, "running": r, "runs_last_hour": volume,
                "jammed": jammed, "jam_since": since if qualifies else None,
                "estimated_requests": estimate, "measurement": coefficient,
                "installation_runs": hard, "drain_eta": None, "exhaustion_eta": None}

    def _robot(self, now):
        if self.robot_snapshot is None:
            return unavailable("robot_evidence_unavailable")
        value = self.robot_snapshot()
        now = self.clock()
        if type(value) is not dict or value.get("configured_identity") != "nathanpayne-robot":
            return unavailable("robot_identity_unavailable")
        observed, reset = value.get("observed_at"), value.get("reset")
        if (not number(observed) or not number(reset) or not 0 <= now - observed <= 120
                or reset <= now or not count(value.get("remaining")) or not count(value.get("limit"))
                or value["limit"] <= 0 or value["remaining"] > value["limit"]):
            return unavailable("robot_evidence_expired", {
                "observed_at": observed if number(observed) and observed <= now else None,
                "configured_identity": "nathanpayne-robot",
                "reset": reset if number(reset) else None,
                "limit": value.get("limit") if count(value.get("limit")) else None,
                "remaining": value.get("remaining") if count(value.get("remaining")) else None,
                "secondary_limited": value.get("secondary_limited") is True})
        # Never publish arbitrary callback fields or response text.
        return {"available": True, "stale": False, "observed_at": observed, "reset": reset,
                "remaining": value["remaining"], "limit": value["limit"],
                "used": value["limit"] - value["remaining"], "kind": "reported",
                "secondary_limited": value.get("secondary_limited") is True,
                "primary_exhausted": value.get("primary_exhausted") is True,
                "configured_identity": "nathanpayne-robot", "repositories": None,
                "attribution": "unavailable"}

    def fetch(self, deadline):
        now = self.clock()
        rows = []
        size = len(self.repos)
        order = self.repos[self._cursor:] + self.repos[:self._cursor]
        self._cursor = (self._cursor + 1) % size
        # Queue reads get their fair share before the slow billing attempt.
        for index, repo in enumerate(order):
            available = deadline - self.monotonic()
            subdeadline = self.monotonic() + max(0, available / (size - index + 1))
            try:
                if available <= 0:
                    raise ClientError("deadline_exceeded")
                row = self._repo_read(repo, subdeadline, now)
                self._last[repo] = row
            except ClientError as exc:
                self._jam.pop(repo, None)
                row = unavailable(exc.category, self._last.get(repo))
                row["repo"] = repo
            except Exception:
                self._jam.pop(repo, None)
                row = unavailable("source_failed", self._last.get(repo))
                row["repo"] = repo
            rows.append(row)
        billing = self._billing_read(deadline, now)
        try:
            robot = self._robot(now)
        except Exception:
            robot = unavailable("source_failed")
        if robot.get("available") is True:
            self._robot_last = copy.deepcopy(robot)
        elif self._robot_last is not None:
            robot = unavailable(robot.get("error", "source_failed"), self._robot_last)
        return Sample({"schema": "actions-budget/v1", "billing": billing, "repositories": sorted(rows, key=lambda row: row["repo"]),
                       "robot": robot, "configuration": self._configuration(now)}, hot=any(row.get("queued") or row.get("running") for row in rows))

    def _configuration(self, now):
        config = {"budget": None, "cycle_start": None, "cycle_end": None}
        budget, start, end = (self.settings.get(key) for key in ("budget", "cycle_start", "cycle_end"))
        if number(budget, 10 ** 9) and budget > 0:
            config["budget"] = budget
        if all(number(value) for value in (start, end)) and start <= now < end and 0 < end - start <= 32 * 86400:
            # API request covers only the current UTC calendar month.
            current = dt.datetime.fromtimestamp(now, dt.timezone.utc)
            month_start = current.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
            next_month = (month_start.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
            if start == month_start.timestamp() and end == next_month.timestamp():
                config.update(cycle_start=start, cycle_end=end)
        return config
