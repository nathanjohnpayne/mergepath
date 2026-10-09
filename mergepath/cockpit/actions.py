"""Read-only Actions observations; unavailable inputs never become estimates."""

import copy
from collections import OrderedDict
import datetime as dt
import json
import math
import re
import time
from decimal import Decimal, InvalidOperation

from .ci import FAILURES, TERMINAL
from .github import ClientError
from .inventory import REPO
from .scheduler import Sample

SAFE = 2 ** 53 - 1
INSTALLATION = "api rate limit exceeded for installation"
# The message as GitHub ends it: a period, `ID`, or the end of the line (or of a JSON value).
MESSAGE = re.compile(r"api rate limit exceeded for installation(?:\.|\s+id\b|\s*$)", re.I)
# What may come before it on an emitted error line (#1842). Bare, after a runner `##[error]`
# marker (not `##[warning]`, which can quote it); after `label: ` prefixes whose last one names an
# error (`gh: `, `Error: `, `RequestError [HttpError]: `, `[tool] ERROR: `), so `note: ` is not one;
# or as the `"message"` value of a JSON response, which is parsed rather than matched (#1846): a
# line that is exactly one JSON object after those prefixes, or a pretty-printed `"message": "..."`
# line ending at the value or one comma after it. Quoted, embedded or wrapped copies
# (`expected {"message": ...} but`, `{"message": ...} but got success`) match none of these.
MARKER = r"(?:##\[error\])?"
LABEL = r"[A-Za-z\[][\w\[\]().\- ]{0,40}:\s+"
ERROR_HEAD = re.compile(rf"{MARKER}(?:{LABEL})*", re.I)
ERROR_WORD = re.compile(r"error|fatal|exception|failed|failure|\bgh\b", re.I)
JSON_FIELD = re.compile(r"\"message\"\s*:\s*(?=\")")
JSON_LIMIT = 8192
# The runner echoes each run step's script between these markers before running it.
PREAMBLE_OPEN, PREAMBLE_CLOSE = "##[group]Run ", "##[endgroup]"
LOG_PREFIX = re.compile(r"^(?:\d{4}-\d\d-\d\dT[0-9:.]+Z )?")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# A gate that runs out of its repository GITHUB_TOKEN usually prints the limit only in its
# job log (observed on nathanpaynedotcom on 2026-10-07), never in run or check output, and
# the busiest repositories are the ones the CI scan covers least. So the installation scan
# reads each repository itself, independently of the CI snapshot: at most every
# SCAN_INTERVAL seconds, the newest SCAN_RUNS failed runs of the last hour, their failed
# jobs, and those jobs' logs, LOG_READS per repository per scan. A completed attempt's jobs
# and a completed job's verdict never change, so both are cached.
SCAN_INTERVAL = 120
SCAN_RUNS = 5
LIST_RUNS = 2 * SCAN_RUNS
LOG_READS = 3
JOB_PAGES = 5
# Failure-class workflow-run conclusions the runs list can filter by (`status=`).
RUN_FAILURES = ("failure", "timed_out", "action_required")
SCAN_CACHE = 1024


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
        elif type(repo) is str and len(repo) <= 200 and REPO.fullmatch(repo):
            key = repo
            repositories[key] = repositories.get(key, Decimal(0)) + amount
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
            "window_start": start, "window_end": end, "provenance": provenance.strip()}


def json_message(line):
    """True when a log line is a JSON response whose `message` is the installation limit.

    Either the whole line after any marker and `label: ` prefixes is one JSON object, or it is a
    pretty-printed `"message": "..."` field with nothing after the value but one comma (#1846).
    """
    rest = line[ERROR_HEAD.match(line).end():]
    if rest.startswith("{"):
        if len(rest) > JSON_LIMIT:
            return False
        try:
            value = json.loads(rest)
        except (ValueError, RecursionError):
            return False
        message = value.get("message") if isinstance(value, dict) else None
    else:
        field = JSON_FIELD.match(rest)
        if not field:
            return False
        try:
            message, end = json.JSONDecoder().raw_decode(rest, field.end())
        except ValueError:
            return False
        if rest[end:].strip() not in ("", ","):
            return False
    return isinstance(message, str) and MESSAGE.match(message) is not None


def logged_limit(text):
    """True when a job log emits the installation-limit message as output.

    Echoed command text is not evidence (#1842): the runner prints each run step's script between
    `##[group]Run` and `##[endgroup]`, and bash xtrace prints commands behind `+`, so a step that
    merely greps for the message would otherwise read as exhausted.
    """
    preamble = False
    for raw in text.splitlines():
        line = LOG_PREFIX.sub("", ANSI.sub("", raw), count=1)
        if preamble:
            preamble = not line.startswith(PREAMBLE_CLOSE)
            continue
        if line.startswith(PREAMBLE_OPEN):
            preamble = True
            continue
        if re.match(r"\++ ", line):
            continue
        line = line.strip()
        if json_message(line):
            return True
        for match in MESSAGE.finditer(line):
            if ERROR_HEAD.fullmatch(line[:match.start()]):
                labels = re.findall(LABEL, line[:match.start()])
                if not labels or ERROR_WORD.search(labels[-1]):
                    return True
    return False


def newest(proofs):
    """Proven run ids, newest run first."""
    return sorted(proofs, key=lambda run: (proofs[run], int(run)), reverse=True)


def iso_epoch(value):
    """Epoch seconds of a zoned ISO-8601 timestamp, or None; a zoneless one is never guessed."""
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        stamp = parsed.timestamp() if parsed.tzinfo is not None else None
    except (AttributeError, TypeError, ValueError, OverflowError):
        return None
    return stamp if number(stamp) else None


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


def ci_observation(envelope, repo, now, max_age=120):
    """Read a copied ci/v1 snapshot without causing a poll or log request.

    max_age is the CI source's observation gap: the launcher passes ci.OBSERVATION_GAP,
    derived from that source's registered cadence, so a snapshot between scans stays usable.
    """
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
            or not 0 <= now - observation["observed_at"] <= max_age):
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
        # An orphaned run (queued with no jobs past ci.ORPHAN_SECONDS) holds no runner and never drains.
        if row.get("status") == "queued" and row.get("orphaned") is not True:
            queued.append(normalized)
        if row.get("status") == "in_progress":
            running.append(normalized.copy())
        if now - 3600 <= created <= now:
            hour.append(normalized.copy())
    return {"complete": True, "stale": False, "observed_at": observation["observed_at"],
            "queued": queued, "running": running, "hour": hour}


class ActionsProvider:
    def __init__(self, client, inventory, *, settings=None, ci_snapshot=None,
                 robot_snapshot=None, clock=time.time, monotonic=time.monotonic, ci_max_gap=120,
                 installation_scan=False):
        self.client, self.clock, self.monotonic = client, clock, monotonic
        # An injected CI snapshot is renewed on the CI source's cadence, not on this source's,
        # so its freshness and jam continuity use that source's observation gap.
        if type(ci_max_gap) not in (int, float) or not math.isfinite(ci_max_gap) or not 0 < ci_max_gap <= 3600:
            raise ValueError("invalid_ci_max_gap")
        self.ci_max_gap = ci_max_gap
        self.repos = tuple(item.repo for item in inventory)
        if not self.repos or len(self.repos) > 100 or any(not REPO.fullmatch(repo) for repo in self.repos):
            raise ValueError("invalid_actions_inventory")
        self.settings = copy.deepcopy(settings) if type(settings) is dict else {}
        self.ci_snapshot, self.robot_snapshot = ci_snapshot, robot_snapshot
        self._billing, self._billing_due, self._billing_period = None, 0, None
        self._last, self._jam, self._cursor = {}, {}, 0
        self._robot_last = None
        self._scans, self._scan_jobs, self._scan_logs = {}, OrderedDict(), OrderedDict()
        # The launcher enables the installation scan; it is the provider's one read beside
        # the injected CI snapshot.
        self.installation_scan = installation_scan is True

    @staticmethod
    def _remember(cache, key, value):
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > SCAN_CACHE:
            cache.popitem(last=False)

    def _installation_scan(self, repo, deadline, now):
        """Exhausted run ids from failed-job logs of the last hour, with when that was observed.

        The first logged installation-limit message settles the scan: one proven exhaustion is a
        complete answer, and an exhausting repository adds fresh failed runs faster than every
        job could be read. Only a clean answer needs every failed job read; a scan that could
        not read them all reports `incomplete` and keeps the last complete observation time. A
        settled scan samples only the newest runs, so a proof stands until its run leaves the
        hour. A failed read keeps the previous runs. Nothing here is estimated: only the logged
        installation-limit message establishes exhaustion.
        """
        last = self._scans.get(repo)
        # A proof leaving its hour inside the interval ends the cached answer: the scan runs again
        # rather than publishing an expired run, or a clean result that run had settled.
        # A scan the deadline cut short retries on the next tick instead: its job lists and log
        # verdicts are cached, so each attempt advances from where the last one stopped.
        if (last is not None and 0 <= now - last["attempted_at"] < SCAN_INTERVAL and not last["retry"]
                and all(now - 3600 <= at <= now for at in last["proofs"].values())):
            return last
        # Proofs map an exhausted run id to its creation time and hold only for the hour after it,
        # pruned before every refresh so a failing or incomplete scan cannot keep an expired one.
        # Both bounds: a clock that stepped back must not keep a proof dated after it.
        proofs = {run: at for run, at in (last["proofs"] if last else {}).items() if now - 3600 <= at <= now}
        # Any rescan inside a window (a deadline retry or a proof-expiry rescan) continues it: three
        # log reads per repository per 120-second window.
        # The window runs on the monotonic clock (#1840): a wall-clock step must not refill it.
        mono = self.monotonic()
        carried = last is not None and 0 <= mono - last["window"] < SCAN_INTERVAL
        state = {"attempted_at": now, "observed_at": last["observed_at"] if last else None,
                 "error": None, "runs": newest(proofs), "proofs": proofs, "retry": False,
                 "window": last["window"] if carried else mono, "reads": last["reads"] if carried else 0}
        try:
            # The cutoff is floored to five minutes so the list URL revalidates as a free 304.
            cutoff = dt.datetime.fromtimestamp((now - 3600) // 300 * 300, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            # Every failure-class run conclusion the list filter accepts (#1840, #1841): a run that
            # timed out or awaits approval can hold the limit too. The newest five of each list
            # contain the newest five overall.
            sample, tails = {}, []
            for conclusion in RUN_FAILURES:
                payload = self.client.get(f"/repos/{repo}/actions/runs?status={conclusion}&created=%3E%3D{cutoff}&per_page={LIST_RUNS}",
                                          deadline=deadline)
                listed = payload.get("workflow_runs") if type(payload) is dict else None
                if type(listed) is not list:
                    raise ClientError("invalid_page")
                for raw in listed:
                    if type(raw) is not dict or not count(raw.get("id")) or raw["id"] == 0:
                        raise ClientError("invalid_page")
                    created = iso_epoch(raw.get("created_at"))
                    if created is None or created > now + 60:
                        raise ClientError("invalid_page")
                    sample.setdefault(raw["id"], (created, raw))
                if len(listed) >= LIST_RUNS:
                    tails.append(created)
            exhausted, complete = [], True
            # Newest first; the stable sort keeps the API's own order among equal creation times, and
            # every run tied with the fifth is sampled too, so a tie across the lists cannot push a
            # timed-out or approval-held run out of the sample.
            ordered = sorted(sample.values(), key=lambda item: item[0], reverse=True)
            boundary = ordered[SCAN_RUNS - 1][0] if len(ordered) >= SCAN_RUNS else None
            # Each list reads twice the sample, so its last row sits on the boundary second only when
            # six or more runs share it; then its next page may hold more tied runs, and the scan
            # cannot claim it sampled every eligible run.
            complete = not (boundary is not None and boundary in tails)
            for created, raw in [item for index, item in enumerate(ordered) if index < SCAN_RUNS or item[0] == boundary]:
                if exhausted:
                    break
                # The coarse cutoff only keeps the URL cacheable; evidence is the exact last hour. A run
                # dated ahead of this clock waits until it enters it, and since it took a sample slot,
                # the scan cannot claim it read every eligible run.
                if created > now:
                    complete = False
                    continue
                if created < now - 3600:
                    continue
                attempt = raw.get("run_attempt", 1)
                if not count(attempt) or attempt == 0:
                    raise ClientError("invalid_page")
                # Caches are keyed on state that changes when a run moves on: an approval-held run
                # resumes as the same run and attempt, so its conclusion and update time are part of
                # the key, and each job's verdict is keyed on the job's own conclusion and completion.
                # Progress through a held run's jobs is kept while it waits, and dropped when it resumes.
                key = (repo, raw["id"], attempt, raw.get("conclusion"), raw.get("updated_at"))
                jobs = self._scan_jobs.get(key)
                if jobs is None:
                    # Every page of the jobs of every attempt so far, bounded: an earlier attempt can hold
                    # the limit a later rerun hides, and a partial list must never read as clean.
                    rows = self.client.pages(f"/repos/{repo}/actions/runs/{raw['id']}/jobs?filter=all&per_page=100",
                                             collection="jobs", max_pages=JOB_PAGES, deadline=deadline)
                    # An unreadable row could be a failed job, so it fails the scan rather than vanishing.
                    if type(rows) is not list or any(type(job) is not dict or not count(job.get("id")) or job["id"] == 0
                                                     or job.get("conclusion") not in TERMINAL for job in rows):
                        raise ClientError("invalid_page")
                    # Every failure-class conclusion, the CI taxonomy: a timed-out job can carry the limit too.
                    jobs = [(str(job["id"]), job["conclusion"], job.get("completed_at")) for job in rows
                            if job["conclusion"] in FAILURES]
                    self._remember(self._scan_jobs, key, jobs)
                for job, conclusion, completed in jobs:
                    verdict = self._scan_logs.get((repo, job, conclusion, completed))
                    if verdict is None:
                        if state["reads"] >= LOG_READS or self.monotonic() >= deadline:
                            complete = False
                            state["retry"] = state["retry"] or self.monotonic() >= deadline
                            continue
                        state["reads"] += 1
                        body = self.client.read_job_log(repo, job, deadline=deadline)
                        text = body.decode("utf-8", "replace") if type(body) is bytes else body if type(body) is str else ""
                        verdict = logged_limit(text)
                        self._remember(self._scan_logs, (repo, job, conclusion, completed), verdict)
                    if verdict:
                        exhausted.append((str(raw["id"]), created))
                        break
            if complete or exhausted or proofs:
                # A settled scan samples only the newest runs, so it cannot disprove an earlier proof:
                # proofs stand until their run leaves the hour, and the newest are listed first. A
                # proof still inside the hour answers the scan on its own, so a scan left incomplete
                # by the read window or a hidden tie still settles while one holds.
                proofs.update(exhausted)
                state["proofs"], state["runs"], state["observed_at"] = proofs, newest(proofs), now
            else:
                # Not clean evidence: the last settled runs stand until a settled scan replaces them.
                state["error"] = "incomplete"
        except ClientError as exc:
            state["error"], state["retry"] = exc.category, exc.category == "deadline_exceeded"
        except Exception:
            state["error"] = "source_failed"
        self._scans[repo] = state
        return state

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
            # Validate after the callback has copied its observation. A CI
            # publication after fetch start must not look future or expire late.
            now = self.clock()
            if (type(value) is not dict or value.get("complete") is not True
                    or value.get("stale") is not False or not number(value.get("observed_at"))
                    or not 0 <= now - value["observed_at"] <= self.ci_max_gap):
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
        gap = self.ci_max_gap if self.ci_snapshot is not None else 120
        comparable = previous is not None and 0 < observed - previous["last"] <= gap
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
        # The installation scan gets its own fair share after the queue reads, before billing.
        for index, row in enumerate(rows if self.installation_scan else []):
            available = deadline - self.monotonic()
            scan = self._installation_scan(row["repo"], self.monotonic() + max(0, available / (size - index + 1)), now)
            # Scan runs stay apart from the CI-derived installation_runs, so the page can age each
            # by its own observation: retained scan runs are last-known once the scan stops settling.
            row["installation_scan"] = {"observed_at": scan["observed_at"], "error": scan["error"], "runs": list(scan["runs"])}
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
                       "robot": robot, "configuration": self._configuration(now)}, hot=any(row.get("queued") or row.get("running") for row in rows)
                      # A deadline-cut scan comes back on the hot cadence rather than the idle one.
                      or any(scan["retry"] for scan in self._scans.values()))

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
