"""Read-only Actions observations and bounded on-demand failed-log excerpts."""

import copy
import datetime
import math
import re
import threading
import time
import urllib.parse
from collections import OrderedDict, deque

from .github import ClientError, MAX_BODY, copy_json_tree, error_category, retry_delay
from .inventory import REPO as REPO_NAME
from .scheduler import Sample

FAILURES = frozenset({'failure', 'timed_out', 'action_required', 'startup_failure'})
LIVE = frozenset({'queued', 'in_progress', 'waiting', 'pending', 'requested'})
SHA = re.compile(r'[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z')
DECIMAL = re.compile(r'[1-9][0-9]{0,79}\Z')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|$))')
TIMESTAMP = re.compile(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s*')


def identity(value):
    if type(value) is int and value > 0:
        value = str(value)
    if type(value) is not str or not DECIMAL.fullmatch(value):
        raise ClientError('invalid_upstream_json')
    return value


def stamp(value):
    if type(value) is not str:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            return None
        result = parsed.timestamp()
        return result if math.isfinite(result) and result >= 0 else None
    except (ValueError, OverflowError, OSError):
        return None


def text(value, limit=1000):
    if type(value) is not str:
        return ''
    return ''.join(c for c in ANSI.sub('', value) if c == '\t' or ord(c) >= 32)[:limit]


def _sha(value):
    if type(value) is not str or not SHA.fullmatch(value):
        raise ClientError('invalid_upstream_json')
    return value.lower()


def _row(value):
    if type(value) is not dict:
        raise ClientError('invalid_upstream_json')
    return value


def _status(value):
    return value if value in LIVE | {'completed'} else 'unknown'


def _conclusion(value):
    return value if value in FAILURES | {'success', 'neutral', 'cancelled', 'skipped', 'stale'} else None


def normalize_check(repo, value, workflows):
    value = _row(value)
    app = value.get('app')
    producer, workflow_run_id = None, None
    if type(app) is dict and app.get('id') is not None:
        app_id = identity(app['id'])
        if app.get('slug') == 'github-actions':
            suite = value.get('check_suite')
            lineage = workflows.get(identity(suite['id'])) if type(suite) is dict and suite.get('id') is not None else None
            if type(lineage) is dict and lineage.get('workflow_id') is not None:
                producer = 'app:' + app_id + ':workflow:' + identity(lineage['workflow_id'])
                if lineage.get('run_id') is not None:
                    workflow_run_id = identity(lineage['run_id'])
        else:
            producer = 'app:' + app_id
    output = value.get('output') if type(value.get('output')) is dict else {}
    diagnostic = text('\n'.join(v for v in (output.get('title'), output.get('summary'), output.get('text')) if type(v) is str), 4000)
    return {'id': identity(value.get('id')), 'repo': repo, 'sha': _sha(value.get('head_sha')),
            'name': text(value.get('name')), 'producer': producer, 'workflow_run_id': workflow_run_id,
            'status': _status(value.get('status')), 'conclusion': _conclusion(value.get('conclusion')),
            'started_at': stamp(value.get('started_at')), 'completed_at': stamp(value.get('completed_at')),
            'diagnostic': diagnostic, 'diagnostic_source': 'check-run output', 'superseded_by': None}


def supersede(checks):
    """Retain history; a different producer or unknown time cannot clear it."""
    for failed in checks:
        if failed['conclusion'] not in FAILURES or failed['producer'] is None or failed['started_at'] is None:
            continue
        if ':workflow:' in failed['producer'] and failed.get('workflow_run_id') is None:
            continue
        candidates = [passed for passed in checks if passed['status'] == 'completed'
                      and passed['conclusion'] == 'success' and passed['started_at'] is not None
                      and passed['started_at'] > failed['started_at']
                      and all(passed[k] == failed[k] for k in ('repo', 'sha', 'name', 'producer'))
                      and passed.get('workflow_run_id') == failed.get('workflow_run_id')]
        if candidates:
            failed['superseded_by'] = min(candidates, key=lambda row: row['started_at'])['id']
    return checks


def normalize_job(value, repo=None):
    value = _row(value)
    steps = value.get('steps')
    if type(steps) is not list:
        raise ClientError('invalid_upstream_json')
    check_url = value.get('check_run_url')
    check_id = None
    if type(check_url) is str:
        match = re.fullmatch(r'https://api\.github\.com/repos/([^/]+/[^/]+)/check-runs/([1-9][0-9]*)', check_url)
        if match:
            if repo is not None and (not REPO_NAME.fullmatch(match.group(1))
                                     or match.group(1).casefold() != repo.casefold()):
                raise ClientError('invalid_upstream_json')
            check_id = identity(match.group(2))
    result = {'id': identity(value.get('id')), 'name': text(value.get('name')), 'check_id': check_id,
              'attempt': identity(value['run_attempt']) if value.get('run_attempt') is not None else None,
              'status': _status(value.get('status')), 'conclusion': _conclusion(value.get('conclusion')),
              'started_at': stamp(value.get('started_at')), 'completed_at': stamp(value.get('completed_at')), 'steps': []}
    for step in steps:
        step = _row(step)
        result['steps'].append({'number': identity(step.get('number')), 'name': text(step.get('name')),
                                'status': _status(step.get('status')), 'conclusion': _conclusion(step.get('conclusion')),
                                'started_at': stamp(step.get('started_at')), 'completed_at': stamp(step.get('completed_at'))})
    if len({row['number'] for row in result['steps']}) != len(result['steps']):
        raise ClientError('invalid_upstream_json')
    return result


def _check_evidence(checks, current):
    failed = [check for check in checks if check['conclusion'] in FAILURES]
    actionable = current is True and any(check['superseded_by'] is None for check in failed)
    severity = 'bump' if actionable else None
    reason = 'Unsuperseded failed check on current HEAD' if actionable else None
    for check in failed:
        if current is not True or check['superseded_by'] is not None:
            continue
        if re.search(r'API rate limit exceeded for installation', check['diagnostic'], re.I):
            severity, reason = 'boulder', 'Observed installation rate-limit failure'
        elif re.search(r'CodeQL[^\n]*(?:not retryable|non[- ]retryable)', check['diagnostic'], re.I):
            severity, reason = 'boulder', 'Observed nonretryable CodeQL failure'
    return {'actionable': actionable, 'severity': severity, 'reason': reason,
            'diagnostics': [{'text': check['diagnostic'], 'source': check['diagnostic_source'], 'check_id': check['id']}
                            for check in checks if check['diagnostic']],
            'superseded': bool(failed) and all(check['superseded_by'] is not None for check in failed)}


def group_runs(repo, raw_runs, jobs, checks, heads):
    groups, rows, ids = {}, [], set()
    for raw in raw_runs:
        raw = _row(raw)
        run_id, attempt = identity(raw.get('id')), identity(raw.get('run_attempt', 1))
        if run_id in ids:
            raise ClientError('invalid_upstream_json')
        ids.add(run_id)
        sha = _sha(raw.get('head_sha'))
        prs = raw.get('pull_requests')
        if type(prs) is not list:
            raise ClientError('invalid_upstream_json')
        numbers = list(dict.fromkeys(identity(_row(pr).get('number')) for pr in prs)) or [None]
        related = [check for check in checks if check['sha'] == sha and check['id'] in {job['check_id'] for job in jobs[run_id]}]
        for number in numbers:
            current = None if number not in heads else heads[number] == sha
            owned = copy.deepcopy(related)
            row = {'key': f'{repo}:{run_id}:{number or "none"}', 'id': run_id, 'attempt': attempt, 'repo': repo,
                   'pr': number, 'sha': sha, 'name': text(raw.get('name')), 'workflow_id': identity(raw.get('workflow_id')),
                   'jobs_scope': 'all-attempts', 'status': _status(raw.get('status')), 'conclusion': _conclusion(raw.get('conclusion')),
                   'created_at': stamp(raw.get('created_at')), 'started_at': stamp(raw.get('run_started_at')),
                   'updated_at': stamp(raw.get('updated_at')), 'current_head': current,
                   'jobs': copy.deepcopy(jobs[run_id]), 'checks': owned, **_check_evidence(owned, current),
                   'check_evidence_unknown': raw.get('conclusion') in FAILURES and not any(c['conclusion'] in FAILURES for c in owned),
                   'rerun_command': f'gh run rerun {run_id} --failed --repo {repo}' if raw.get('conclusion') in FAILURES else None}
            rows.append(row)
            key = (number, sha)
            groups.setdefault(key, {'repo': repo, 'pr': number, 'sha': sha, 'run_keys': []})['run_keys'].append(row['key'])
    return rows, list(groups.values())


def _group_check_rows(repo, checks, heads, runs, groups):
    claimed = {check['id'] for run in runs for check in run['checks']}
    rows, by_key = [], {(group['pr'], group['sha']): group for group in groups}
    unmatched = [check for check in checks if check['id'] not in claimed]
    for sha in sorted({check['sha'] for check in unmatched}):
        related = [check for check in unmatched if check['sha'] == sha]
        # A check is commit-scoped, not an invented Actions run. Open HEADs
        # establish current PR ownership; observed run groups retain old history.
        numbers = list(dict.fromkeys([number for number, head in heads.items() if head == sha]
                                     + [group['pr'] for group in groups if group['sha'] == sha and group['pr'] is not None])) or [None]
        for number in numbers:
            current = None if number not in heads else heads[number] == sha
            owned = copy.deepcopy(related)
            active = [check for check in owned if check['status'] in LIVE]
            status = ('in_progress' if any(check['status'] == 'in_progress' for check in active) else active[0]['status']) if active else (
                'completed' if all(check['status'] == 'completed' for check in owned) else 'unknown')
            conclusion = 'failure' if any(check['conclusion'] in FAILURES for check in owned) else (
                'success' if all(check['status'] == 'completed' and check['conclusion'] == 'success' for check in owned) else None)
            row = {'kind': 'checks', 'key': f'{repo}:checks:{sha}:{number or "none"}', 'repo': repo, 'pr': number, 'sha': sha,
                   'id': None, 'attempt': None, 'workflow_id': None, 'name': 'Check runs', 'jobs_scope': 'none', 'jobs': [],
                   'status': status, 'conclusion': conclusion, 'created_at': None, 'started_at': None, 'updated_at': None,
                   'current_head': current, 'checks': owned, **_check_evidence(owned, current),
                   'check_evidence_unknown': any(check['status'] == 'unknown' or check['status'] == 'completed' and check['conclusion'] is None for check in owned),
                   'rerun_command': None}
            rows.append(row)
            key = (number, sha)
            if key not in by_key:
                by_key[key] = {'repo': repo, 'pr': number, 'sha': sha, 'run_keys': []}
                groups.append(by_key[key])
            by_key[key].setdefault('check_keys', []).append(row['key'])
    return rows


class CIProvider:
    def __init__(self, client, inventory, *, clock=time.time, monotonic=time.monotonic, max_pages=10, recent_seconds=86400):
        self.client, self.inventory, self.clock = client, tuple(inventory), clock
        self.monotonic, self._offset = monotonic, 0
        self.max_pages = max_pages
        if type(recent_seconds) is not int or not 0 < recent_seconds <= 2**53 - 1:
            raise ValueError('invalid_recent_window')
        self.recent_seconds = recent_seconds
        self._records, self._failures, self._jobs_cache = {}, {}, OrderedDict()

    def _repo(self, repo, deadline):
        base = '/repos/' + repo
        pulls = self.client.pages(base + '/pulls?state=open&per_page=100', max_pages=self.max_pages, deadline=deadline)
        heads = {identity(_row(pr).get('number')): _sha(_row(pr.get('head')).get('sha')) for pr in pulls}
        cutoff = datetime.datetime.fromtimestamp(max(0, self.clock() - self.recent_seconds), datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
        queries = ['created=' + urllib.parse.quote('>=' + cutoff, safe='')] + ['status=' + status for status in sorted(LIVE)]
        run_by_id = OrderedDict()
        for query in queries:
            for raw in self.client.pages(base + '/actions/runs?per_page=100&' + query, collection='workflow_runs', max_pages=self.max_pages, deadline=deadline):
                run_by_id[identity(_row(raw).get('id'))] = raw
        runs = list(run_by_id.values())
        workflows, jobs, checks = {}, {}, []
        for raw in runs:
            raw = _row(raw)
            run_id = identity(raw.get('id'))
            suite_id = raw.get('check_suite_id')
            if suite_id is not None:
                suite = identity(suite_id)
                lineage = {'workflow_id': identity(raw.get('workflow_id')), 'run_id': run_id}
                # Conflicting suite/run observations never choose a convenient lineage.
                workflows[suite] = lineage if suite not in workflows or workflows[suite] == lineage else None
            job_key = (repo, run_id, identity(raw.get('run_attempt', 1)))
            if raw.get('status') == 'completed' and job_key in self._jobs_cache:
                jobs[run_id] = copy.deepcopy(self._jobs_cache[job_key])
                self._jobs_cache.move_to_end(job_key)
            else:
                jobs[run_id] = [normalize_job(job, repo) for job in self.client.pages(
                    base + '/actions/runs/' + run_id + '/jobs?filter=all&per_page=100', collection='jobs',
                    max_pages=self.max_pages, deadline=deadline)]
                if raw.get('status') == 'completed':
                    self._jobs_cache[job_key] = copy.deepcopy(jobs[run_id])
                    self._jobs_cache.move_to_end(job_key)
                    while len(self._jobs_cache) > 256:
                        self._jobs_cache.popitem(last=False)
        for sha in sorted({_sha(_row(run).get('head_sha')) for run in runs} | set(heads.values())):
            checks.extend(normalize_check(repo, check, workflows) for check in self.client.pages(
                base + '/commits/' + sha + '/check-runs?filter=all&per_page=100', collection='check_runs',
                max_pages=self.max_pages, deadline=deadline))
        if len({check['id'] for check in checks}) != len(checks):
            raise ClientError('invalid_upstream_json')
        checks = supersede(checks)
        rows, groups = group_runs(repo, runs, jobs, checks, heads)
        return rows, groups, _group_check_rows(repo, checks, heads, rows, groups)

    def __call__(self, deadline):
        rows, groups, check_rows, observations = [], [], [], []
        budget_deadline = deadline - .25
        ordered = self.inventory[self._offset:] + self.inventory[:self._offset]
        self._offset = (self._offset + 1) % max(1, len(self.inventory))
        for item in ordered:
            repo, now = item.repo, self.clock()
            old = self._records.get(repo)
            if old and old['stale'] and old['retry_at'] > now:
                record = copy.deepcopy(old)
            else:
                try:
                    if self.monotonic() >= budget_deadline:
                        raise ClientError('deadline_exceeded')
                    repo_rows, repo_groups, repo_checks = self._repo(repo, budget_deadline)
                    record = {'repo': repo, 'observed_at': self.clock(), 'attempted_at': now,
                              'stale': False, 'error': None, 'retry_at': None,
                              'runs': repo_rows, 'groups': repo_groups, 'check_rows': repo_checks}
                    self._failures[repo] = 0
                except Exception as exc:
                    category = error_category(exc.category) if isinstance(exc, ClientError) else 'source_failed'
                    failures = self._failures.get(repo, 0) + 1
                    self._failures[repo] = failures
                    delay = min(900, 20 * 2 ** min(failures - 1, 16))
                    if isinstance(exc, ClientError):
                        delay = max(delay, retry_delay(exc.retry_after))
                    retry = now + delay
                    if not math.isfinite(retry):
                        retry = now + 20
                    record = copy.deepcopy(old) if old else {'repo': repo, 'observed_at': None, 'runs': [], 'groups': [], 'check_rows': []}
                    record.update(attempted_at=now, stale=True, error=category, retry_at=now if category == 'deadline_exceeded' else retry)
            self._records[repo] = copy.deepcopy(record)
        for item in self.inventory:
            record = self._records[item.repo]
            rows.extend(copy.deepcopy(record['runs']))
            groups.extend(copy.deepcopy(record['groups']))
            check_rows.extend(copy.deepcopy(record['check_rows']))
            observations.append({k: record[k] for k in ('repo', 'observed_at', 'attempted_at', 'stale', 'error', 'retry_at')})
        data = {'schema': 'ci/v1', 'runs': rows, 'groups': groups, 'repositories': observations, 'recent_seconds': self.recent_seconds, 'check_rows': check_rows}
        return Sample(copy_json_tree(data), hot=any(row['status'] in LIVE for row in rows + check_rows) or any(o['stale'] for o in observations))


def extract_fail_lines(body, step):
    if type(body) is not bytes or len(body) > MAX_BODY:
        raise ClientError('response_too_large')
    lines, truncated, size = deque(), False, 0
    start, end = step.get('started_at'), step.get('completed_at')
    scoped = start is not None and end is not None
    for raw in body.decode('utf-8', 'replace').splitlines():
        clean = text(raw, MAX_BODY)
        timestamp = TIMESTAMP.match(clean)
        if scoped:
            when = stamp(timestamp.group(1)) if timestamp else None
            # An integral REST start loses subsecond precision; a failure in
            # that second can precede the actual selected step. Untimed failures
            # and the completion second's remainder are also ambiguous.
            ambiguous_start = when is not None and start == math.floor(start) and math.floor(when) == start
            if 'FAIL:' in clean and (when is None or ambiguous_start or (when > end and math.floor(when) == math.floor(end))):
                return extract_fail_lines(body, {})
            if when is None or not start <= when <= end:
                continue
        if 'FAIL:' not in clean:
            continue
        clean = clean[clean.index('FAIL:'):]
        if len(clean) > 1000:
            clean, truncated = clean[:1000], True
        encoded = len(clean.encode('utf-8'))
        lines.append(clean)
        size += encoded
        while len(lines) > 80 or size > 32768:
            truncated = True
            size -= len(lines.popleft().encode('utf-8'))
    return {'status': 'ok' if lines else 'empty', 'lines': list(lines), 'truncated': truncated,
            'scope': 'step-time-window' if scoped else 'job', 'source': 'Actions job log', 'error': None}


class LogExcerptCache:
    """No URL/auth/transport: validate observed identities before fixed reads."""
    def __init__(self, inventory, read_log, *, clock=time.monotonic, ttl=120, max_jobs=32):
        self.repos = frozenset(item.repo for item in inventory)
        self.read_log, self.clock, self.ttl, self.max_jobs = read_log, clock, ttl, max_jobs
        self.cache, self.pending = OrderedDict(), {}
        self.condition = threading.Condition()
        self.slots = threading.BoundedSemaphore(2)

    def handle(self, params, envelope, *, deadline):
        expected = {'repo', 'run', 'attempt', 'job', 'step'}
        if type(params) is not dict or set(params) != expected or any(type(v) is not str for v in params.values()):
            raise ValueError('invalid_excerpt_request')
        if params['repo'] not in self.repos:
            raise ValueError('invalid_excerpt_request')
        if any(not DECIMAL.fullmatch(params[k]) for k in expected - {'repo'}):
            raise ValueError('invalid_excerpt_request')
        data = envelope.get('data') if type(envelope) is dict else None
        if type(data) is not dict or data.get('schema') != 'ci/v1':
            return self._unavailable('upstream_unavailable')
        row = next((r for r in data['runs'] if all(r[k] == params[p] for k, p in [('repo', 'repo'), ('id', 'run'), ('attempt', 'attempt')])), None)
        job = next((j for j in row['jobs'] if j['id'] == params['job']), None) if row else None
        step = next((s for s in job['steps'] if s['number'] == params['step']), None) if job else None
        if step is None or step['conclusion'] not in FAILURES:
            raise ValueError('invalid_excerpt_request')
        if envelope.get('stale') is True or any(o['repo'] == params['repo'] and o['stale'] for o in data.get('repositories', [])):
            return {'status': 'stale', 'lines': [], 'truncated': False, 'scope': None, 'source': 'Actions job log', 'error': None}
        key = tuple(params[k] for k in ('repo', 'run', 'attempt', 'job'))
        with self.condition:
            while key in self.pending:
                remaining = deadline - self.clock()
                if remaining <= 0:
                    return self._unavailable('deadline_exceeded')
                self.condition.wait(remaining)
            entry = self.cache.get(key)
            if entry and entry[0] > self.clock():
                self.cache.move_to_end(key)
                return self._project(entry[1], step)
            if not self.slots.acquire(blocking=False):
                return self._unavailable('upstream_backoff')
            self.pending[key] = True
        try:
            if deadline <= self.clock():
                result = self._unavailable('deadline_exceeded')
            else:
                try:
                    body = self.read_log(params['repo'], params['job'], deadline)
                    if type(body) is not bytes or len(body) > MAX_BODY:
                        raise ClientError('response_too_large')
                    result = body if self.clock() < deadline else self._unavailable('deadline_exceeded')
                except ClientError as exc:
                    result = self._unavailable(error_category(exc.category))
                except Exception:
                    result = self._unavailable('upstream_unavailable')
            if type(result) is bytes or result['error'] in {'permission_denied', 'response_too_large'}:
                with self.condition:
                    self.cache[key] = (self.clock() + self.ttl, result)
                    self.cache.move_to_end(key)
                    while len(self.cache) > self.max_jobs:
                        self.cache.popitem(last=False)
            return self._project(result, step)
        finally:
            with self.condition:
                self.pending.pop(key, None)
                self.slots.release()
                self.condition.notify_all()

    @staticmethod
    def _unavailable(category):
        return {'status': 'denied' if category == 'permission_denied' else 'unavailable',
                'lines': [], 'truncated': False, 'scope': None, 'source': 'Actions job log', 'error': category}

    @staticmethod
    def _project(result, step):
        return extract_fail_lines(result, step) if type(result) is bytes else copy.deepcopy(result)
