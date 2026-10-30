#!/usr/bin/env python3
"""Re-run a failed feedback-archive relay that left no terminal marker (#2907).

The scheduled Codex P1 sweep holds a read-only PR while any trusted source
run lacks a `status=complete|failed` relay marker. A relay whose own failure
path could not post `status=failed` (an Actions/API incident) left the PR
held until someone re-ran the relay by hand (matchline#620, 2026-10-30).

This helper never clears anything. For each pending source run that
completed at least --stall-seconds ago, it looks for the relay runs created
since then. Any relay run still queued or running means a relay may yet
land, so nothing is done. Otherwise it reads each failed relay run's job log,
binds it to its source through the runner-rendered `SOURCE_RUN_ID` env line,
and re-runs that relay run (a re-run keeps the run id and replays the same
workflow_run payload). The sweep stays pending until the relay posts its own
marker. Each relay is re-run at most --max-attempts - 1 times.

stdin:  JSON list of pending source runs: [{id, status, updated_at}, ...]
stdout: JSON {stalled, in_flight, rerun, unmatched}
exit 2: relay history unreadable or saturated; the caller stays pending.
"""
import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys

WORKFLOW = 'codex-feedback-archive-relay.yml'
FAILED = {'failure', 'cancelled', 'timed_out', 'startup_failure'}
ESCAPE_FLAG = '--allow-escape-sequences'
SKEW = 300
MAX_LOG_READS = 20


def epoch(stamp):
    try:
        return int(dt.datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp())
    except (AttributeError, TypeError, ValueError):
        return None


def iso(seconds):
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def log_source(log):
    """SOURCE_RUN_ID from a step's runner-rendered trailing env block."""
    clean = re.sub(r'\x1b\[[0-9;]*m', '', log)
    clean = re.sub(r'(?m)^\d{4}-\d\d-\d\dT\S+ ', '', clean)
    for block in re.findall(r'(?ms)^##\[group\]Run .*?^##\[endgroup\]', clean):
        envs = list(re.finditer(r'(?m)^( {0,2})env:\n((?:\1  [A-Z_]+: [^\n]*\n)+)##\[endgroup\]', block))
        if not envs:
            continue
        values = dict(re.findall(r'(?m)^ +([A-Z_]+): ([^\n]*)$', envs[-1].group(2)))
        if re.fullmatch(r'[1-9][0-9]*', values.get('SOURCE_RUN_ID', '')):
            return int(values['SOURCE_RUN_ID'])
    return None


class GitHub:
    def __init__(self, repo):
        self.repo = repo
        self.gh = shutil.which('gh')
        if not self.gh:
            raise ValueError('gh executable required')
        usage = subprocess.run([self.gh, 'api', '--help'], capture_output=True, text=True, timeout=20)
        self.escape = ESCAPE_FLAG in usage.stdout + usage.stderr

    def get(self, endpoint, *, pages=False, text=False):
        argv = ([self.gh, 'api'] + (['--paginate', '--slurp'] if pages else [])
                + ([ESCAPE_FLAG] if text and self.escape else [])
                + [f'repos/{self.repo}/{endpoint}'])
        result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError(f'could not read {endpoint}')
        return result.stdout if text else json.loads(result.stdout)

    def rerun(self, run_id):
        result = subprocess.run([self.gh, 'api', '-X', 'POST', f'repos/{self.repo}/actions/runs/{run_id}/rerun'], capture_output=True, text=True, timeout=60)  # NO_BARE_GH_WRITE_EXEMPT: Actions-only re-run of a failed relay run under the scheduled sweep's workflow GITHUB_TOKEN (actions:write), never interactive author/reviewer PATs.
        return result.returncode == 0


def recover(github, pending, now, stall, max_attempts):
    done = {}
    for row in pending:
        when = epoch(row.get('updated_at')) if isinstance(row, dict) else None
        if (isinstance(row, dict) and type(row.get('id')) is int and row.get('status') == 'completed'
                and when is not None and now - when >= stall):
            done[row['id']] = when
    report = {'stalled': sorted(done), 'in_flight': False, 'rerun': [], 'unmatched': []}
    if not done:
        return report
    since = iso(min(done.values()) - SKEW)
    pages = github.get(f'actions/workflows/{WORKFLOW}/runs?created=%3E%3D{since}&per_page=100', pages=True)
    if not isinstance(pages, list) or not all(isinstance(p, dict) and isinstance(p.get('workflow_runs'), list) for p in pages):
        raise ValueError('relay run history unavailable')
    if pages and (pages[0].get('total_count') or 0) >= 1000:
        raise ValueError('relay run history saturated the API ceiling')
    runs = [run for page in pages for run in page['workflow_runs'] if isinstance(run, dict)]
    if any(run.get('status') != 'completed' for run in runs):
        report['in_flight'] = True
        return report
    candidates = sorted((run for run in runs
                         if run.get('conclusion') in FAILED and type(run.get('id')) is int
                         and type(run.get('run_attempt')) is int and run['run_attempt'] < max_attempts
                         and epoch(run.get('created_at')) is not None),
                        key=lambda run: run['created_at'])
    matched = set()
    for run in candidates[:MAX_LOG_READS]:
        jobs = github.get(f'actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs')
        for job in (jobs.get('jobs') or []) if isinstance(jobs, dict) else []:
            if not isinstance(job, dict) or type(job.get('id')) is not int:
                continue
            source = log_source(github.get(f'actions/jobs/{job["id"]}/logs', text=True))
            if source is None:
                continue
            if source in done and source not in matched and epoch(run['created_at']) >= done[source] - SKEW:
                if github.rerun(run['id']):
                    report['rerun'].append(run['id'])
                    matched.add(source)
                else:
                    print(f'could not re-run relay run {run["id"]}', file=sys.stderr)
            break
    report['unmatched'] = sorted(set(done) - matched)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--now', required=True, type=int)
    parser.add_argument('--stall-seconds', required=True, type=int)
    parser.add_argument('--max-attempts', type=int, default=3)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', args.repo):
        parser.error('valid repository required')
    pending = json.load(sys.stdin)
    if not isinstance(pending, list):
        raise ValueError('pending source runs unavailable')
    print(json.dumps(recover(GitHub(args.repo), pending, args.now, args.stall_seconds, args.max_attempts)))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TypeError, KeyError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        print(f'relay stall recovery unavailable: {error}', file=sys.stderr)
        raise SystemExit(2)
