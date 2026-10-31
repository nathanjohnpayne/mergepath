#!/usr/bin/env python3
"""Re-run a failed feedback-archive relay that left no terminal marker (#2907).

The scheduled Codex P1 sweep holds a read-only PR while any trusted source
run lacks a `status=complete|failed` relay marker. A relay whose own failure
path could not post `status=failed` (an Actions/API incident) left the PR
held until someone re-ran the relay by hand (matchline#620, 2026-10-30).

This helper never clears anything. For each pending source run that
completed at least --stall-seconds ago, it reads the job logs of failed relay
runs created since then. It binds each one to its source through the
runner-rendered `SOURCE_RUN_ID` env line, then re-runs a relay bound to a
stalled source. A re-run keeps the run id and replays the same workflow_run
payload. The binding is what keeps an in-flight relay safe. Only a completed,
failed relay created at or after its source's latest completion is re-run.
Another relay for that source would need another completion, which moves the
completion time and restarts the stall clock. Queued or running relays, for
any PR, are neither read nor waited on (#2908 review). The sweep stays
pending until the relay posts its own marker. Each relay is re-run at most
--max-attempts - 1 times.

stdin:  JSON list of pending source runs: [{id, status, updated_at, run_started_at}, ...]
stdout: JSON {stalled, rerun, unmatched, incomplete}
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
MAX_LOG_READS = 20
# The scheduled sweep's cadence: the read window advances once per slot.
SWEEP_SECONDS = 1800


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
    # done: completion of each stalled source's latest attempt. started: when
    # that attempt began. A re-run attempt starts only after the previous one
    # completed, so a relay created before `started` belongs to an earlier
    # attempt and must never be re-run for this one (#2908 review). A source
    # without a readable start time is never bound, so it stays pending.
    done, started = {}, {}
    for row in pending:
        if not isinstance(row, dict):
            continue
        when, began = epoch(row.get('updated_at')), epoch(row.get('run_started_at'))
        if (type(row.get('id')) is int and row.get('status') == 'completed'
                and when is not None and began is not None and now - when >= stall):
            done[row['id']], started[row['id']] = when, began
    report = {'stalled': sorted(done), 'rerun': [], 'unmatched': [], 'incomplete': False}
    if not done:
        return report
    since = iso(min(started.values()))
    pages = github.get(f'actions/workflows/{WORKFLOW}/runs?created=%3E%3D{since}&per_page=100', pages=True)
    if not isinstance(pages, list) or not all(isinstance(p, dict) and isinstance(p.get('workflow_runs'), list) for p in pages):
        raise ValueError('relay run history unavailable')
    if pages and (pages[0].get('total_count') or 0) >= 1000:
        raise ValueError('relay run history saturated the API ceiling')
    runs = [run for page in pages for run in page['workflow_runs'] if isinstance(run, dict)]
    # A relay is created when its source completes, so read the failed runs
    # nearest a stalled source's completion first. Oldest-first let unrelated
    # failures fill the bounded read budget on every sweep (#2908 review).
    def distance(run):
        created = epoch(run.get('created_at'))
        gaps = [created - done[source] for source in done if created is not None and created >= started[source]]
        return min(abs(gap) for gap in gaps) if gaps else None

    candidates = sorted((run for run in runs
                         if run.get('status') == 'completed' and run.get('conclusion') in FAILED
                         and type(run.get('id')) is int
                         and type(run.get('run_attempt')) is int and run['run_attempt'] < max_attempts
                         and distance(run) is not None),
                        key=lambda run: (distance(run), run['id']))
    # Nearest-first alone still reads the same prefix every sweep, so a
    # delayed relay behind MAX_LOG_READS nearer failures would never be read
    # (#2908 review). With more candidates than the bound, the window starts
    # at an offset that advances by MAX_LOG_READS each sweep slot, so every
    # candidate is read within ceil(n / MAX_LOG_READS) sweeps.
    window = candidates
    if len(candidates) > MAX_LOG_READS:
        offset = (now // SWEEP_SECONDS) * MAX_LOG_READS % len(candidates)
        window = candidates[offset:] + candidates[:offset]
    matched = set()
    for run in window[:MAX_LOG_READS]:
        # One unreadable candidate is unbindable, not a reason to stop: the
        # order repeats every sweep, so aborting here could starve this PR's
        # relay forever (#2908 review). Unreadable history still exits 2.
        try:
            jobs = github.get(f'actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs')
        except (ValueError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            print(f'skipping relay run {run["id"]}: {error}', file=sys.stderr)
            continue
        for job in (jobs.get('jobs') or []) if isinstance(jobs, dict) else []:
            if not isinstance(job, dict) or type(job.get('id')) is not int:
                continue
            try:
                source = log_source(github.get(f'actions/jobs/{job["id"]}/logs', text=True))
            except (ValueError, subprocess.TimeoutExpired) as error:
                print(f'skipping relay run {run["id"]}: {error}', file=sys.stderr)
                break
            if source is None:
                continue
            if source in done and source not in matched and epoch(run['created_at']) >= started[source]:
                if github.rerun(run['id']):
                    report['rerun'].append(run['id'])
                    matched.add(source)
                else:
                    print(f'could not re-run relay run {run["id"]}', file=sys.stderr)
            break
    report['unmatched'] = sorted(set(done) - matched)
    report['incomplete'] = bool(report['unmatched']) and len(candidates) > MAX_LOG_READS
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
