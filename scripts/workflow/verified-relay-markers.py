#!/usr/bin/env python3
"""Promote relay completion only after authentic default-workflow evidence."""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time

PATH = '.github/workflows/codex-feedback-archive-relay.yml'
STEP = 'Persist archive and publish the exact-head gate'
MARKER = re.compile(r'^<!-- mergepath-feedback-archive-relay:v(?P<version>[12]) run=(?P<source>[1-9][0-9]*)(?: publisher=(?P<publisher>[1-9][0-9]*))? status=(?P<status>complete|failed) -->$')


class ReadBudgetExhausted(ValueError):
    pass


def log_binds_persist(log, source, pr):
    """Read runner-generated env blocks, never arbitrary application output."""
    clean = re.sub(r'\x1b\[[0-9;]*m', '', log)
    clean = re.sub(r'(?m)^\d{4}-\d\d-\d\dT\S+ ', '', clean)
    for block in re.findall(r'(?ms)^##\[group\]Run .*?^##\[endgroup\]', clean):
        env = block.rsplit('\n  env:\n', 1)
        if len(env) != 2:
            continue
        values = dict(re.findall(r'(?m)^    ([A-Z_]+): ([^\n]*)$', env[1]))
        if (values.get('SOURCE_RUN_ID') == str(source) and values.get('PR_NUMBER') == str(pr)
                and values.get('HANDOFF_FILE', '').endswith('/codex-p1-read-only-handoff.json')):
            return True
    return False


class Evidence:
    def __init__(self, repo, pr):
        self.repo, self.pr = repo, pr
        self.gh = shutil.which('gh')
        if not self.gh or not os.path.isabs(self.gh):
            raise ValueError('absolute gh executable required')
        self.deadline = time.monotonic() + 60
        self.cache = {}
        self.read_cache = {}
        self.workflow = None

    def api(self, endpoint, *, pages=False, text=False):
        key = endpoint, pages, text
        if key in self.read_cache:
            return self.read_cache[key]
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ReadBudgetExhausted('relay provenance read budget exhausted')
        argv = [self.gh, 'api'] + (['--paginate', '--slurp'] if pages else []) + [f'repos/{self.repo}' + ('/' + endpoint if endpoint else '')]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=min(remaining, 20))
        if result.returncode:
            if 'HTTP 404' in result.stderr or 'HTTP 410' in result.stderr:
                self.read_cache[key] = None
                return None
            raise ValueError(f'could not read relay provenance endpoint {endpoint}')
        value = result.stdout if text else json.loads(result.stdout)
        self.read_cache[key] = value
        return value

    def trusted_run(self, run, publisher):
        if not isinstance(run, dict):
            return False
        if self.workflow is None:
            self.workflow = self.api('actions/workflows/codex-feedback-archive-relay.yml')
            if (not isinstance(self.workflow, dict) or type(self.workflow.get('id')) is not int
                    or self.workflow.get('path') != PATH):
                raise ValueError('canonical relay workflow identity unavailable')
        # GitHub runs workflow_run workflows from the default branch. The
        # stable workflow id and event prove that execution lane even after
        # a branch rename; old run metadata is not rewritten by the rename.
        branch = run.get('head_branch')
        return not (run.get('id') != publisher or run.get('event') != 'workflow_run'
                or run.get('workflow_id') != self.workflow['id']
                or not isinstance(branch, str) or not branch
                or run.get('path') not in (PATH, PATH + '@' + branch)
                or str((run.get('repository') or {}).get('full_name')).lower() != self.repo.lower()
                or not re.fullmatch('[0-9a-f]{40}', run.get('head_sha', '')))

    def proves(self, publisher, source):
        key = publisher, source
        if key in self.cache:
            return self.cache[key]
        self.cache[key] = False
        if not self.trusted_run(self.api(f'actions/runs/{publisher}'), publisher):
            return False
        pages = self.api(f'actions/runs/{publisher}/jobs?filter=all&per_page=100', pages=True)
        if not isinstance(pages, list) or not all(isinstance(page, dict) and isinstance(page.get('jobs'), list) for page in pages):
            raise ValueError('relay job metadata unavailable')
        for job in [job for page in pages for job in page['jobs']]:
            if job.get('run_id') != publisher:
                raise ValueError('relay job belongs to another run')
            if not any(step.get('name') == STEP and step.get('conclusion') == 'success' for step in job.get('steps', [])):
                continue
            log = self.api(f'actions/jobs/{job["id"]}/logs', text=True)
            if log and log_binds_persist(log, source, self.pr):
                self.cache[key] = True
                return True
        return False

    def legacy_proves(self, source, created_at):
        deadline = self.deadline
        self.deadline = min(deadline, time.monotonic() + 10)
        try:
            return self.recover_legacy(source, created_at)
        except (ReadBudgetExhausted, subprocess.TimeoutExpired):
            return False  # Unproven legacy evidence grants no completion.
        finally:
            self.deadline = deadline

    def recover_legacy(self, source, created_at):
        # Legacy markers carry no publisher id. Recover it from authentic
        # workflow history near their posting or the source's original/rerun
        # dates. Deleted/expired logs grant no authority; no PAT substitution.
        source_run = self.api(f'actions/runs/{source}')
        stamps = [created_at] + ([source_run.get('created_at'), source_run.get('updated_at')] if isinstance(source_run, dict) else [])
        candidates = {}
        for stamp in dict.fromkeys(stamps):
            if not isinstance(stamp, str) or not re.match(r'^\d{4}-\d\d-\d\dT', stamp):
                continue
            day = dt.date.fromisoformat(stamp[:10])
            end = day + dt.timedelta(days=1)
            pages = self.api(f'actions/workflows/codex-feedback-archive-relay.yml/runs?event=workflow_run&created={day}..{end}&per_page=100', pages=True)
            if not isinstance(pages, list) or not all(isinstance(page, dict) and isinstance(page.get('workflow_runs'), list) for page in pages):
                raise ValueError('legacy relay history unavailable')
            for page in pages:
                for run in page['workflow_runs']:
                    if (run.get('conclusion') == 'success' and type(run.get('id')) is int
                            and self.trusted_run(run, run['id'])):
                        candidates[run['id']] = run
        # Metadata rejects other workflows before expensive job/log reads.
        # Nearest timestamps win, not the highest ids from unrelated reruns.
        def distance(run):
            try:
                when = dt.datetime.fromisoformat(run['created_at'].replace('Z', '+00:00'))
                return min(abs((when - dt.datetime.fromisoformat(stamp.replace('Z', '+00:00'))).total_seconds())
                           for stamp in stamps if isinstance(stamp, str))
            except (ValueError, TypeError, KeyError):
                return float('inf')

        for publisher in sorted(candidates, key=lambda item: (distance(candidates[item]), -item))[:3]:
            if self.proves(publisher, source):
                return True
        return False


def verified(comments, evidence):
    result = []
    eligible = []
    for index, comment in enumerate(comments):
        if (comment.get('user') or {}).get('login') != 'github-actions[bot]':
            continue
        marker = MARKER.fullmatch(comment.get('body', ''))
        if not marker:
            continue
        source = int(marker['source'])
        if marker['version'] == '2' and not marker['publisher']:
            continue
        if marker['version'] == '1' and marker['publisher']:
            continue
        eligible.append((index, comment, marker))
    # Direct publisher proofs precede optional legacy recovery, so old history
    # cannot spend the deadline needed to verify current v2 completions.
    for index, comment, marker in sorted(eligible, key=lambda item: item[2]['version'] == '1' and item[2]['status'] == 'complete'):
        source = int(marker['source'])
        if marker['status'] == 'complete':
            if not (evidence.proves(int(marker['publisher']), source) if marker['publisher']
                    else evidence.legacy_proves(source, comment.get('created_at'))):
                continue
        # Normalize for the existing terminal-state reducer. Only completion
        # has subtraction authority; an unverified failure remains fail-closed.
        result.append((index, dict(comment, body=f'<!-- mergepath-feedback-archive-relay:v1 run={source} status={marker["status"]} -->')))
    return [comment for _, comment in sorted(result)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', required=True, type=int)
    args = parser.parse_args()
    if args.pr < 1 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', args.repo):
        parser.error('valid repository and PR required')
    comments = json.load(sys.stdin)
    if not isinstance(comments, list) or not all(isinstance(comment, dict) for comment in comments):
        raise ValueError('relay comments unavailable')
    print(json.dumps(verified(comments, Evidence(args.repo, args.pr))))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TypeError, KeyError, AttributeError, subprocess.TimeoutExpired) as error:
        print(f'relay provenance unavailable: {error}', file=sys.stderr)
        raise SystemExit(2)
