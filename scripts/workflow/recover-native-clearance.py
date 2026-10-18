#!/usr/bin/env python3
"""Rerun actual native MCG jobs after trusted clearance; never publish a verdict."""
import json
import re
import subprocess
import sys

CONTEXT = 'Merge clearance gate'
WORKFLOW = '.github/workflows/merge-clearance-gate.yml'
SHA = re.compile(r'[a-f0-9]{40}')


def api(repo, suffix, *, method='GET', paginate=False):
    args = ['gh', 'api', '-X', method, f'repos/{repo}/{suffix}']
    if paginate:
        args += ['--paginate', '--slurp']
    raw = subprocess.check_output(args, text=True, timeout=90)
    return json.loads(raw) if raw.strip() else None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def live_pair(repo, tuple_):
    pr = api(repo, f'pulls/{tuple_["pr"]}')
    require(pr['number'] == tuple_['pr'] and pr['state'] == 'open'
            and pr['base']['repo']['full_name'] == repo
            and pr['head']['sha'] == tuple_['head'] and pr['base']['sha'] == tuple_['base'],
            'PR/head/base drift or invalid repository')
    require(api(repo, 'commits/HEAD')['sha'] == tuple_['revision'], 'trusted revision drift')
    return pr


def current_generation(repo, tuple_):
    pages = api(repo, f'commits/{tuple_["head"]}/check-runs?check_name=Merge%20clearance%20gate&filter=latest&per_page=100', paginate=True)
    runs = [r for page in pages for r in page['check_runs'] if r['name'] == CONTEXT
            and r.get('app', {}).get('slug') == 'github-actions']
    synthetic = [r for r in runs if not r.get('external_id')]
    require(synthetic, 'missing publisher generation')
    newest = max(synthetic, key=lambda r: r['id'])
    binding = dict(repo=repo, pr=tuple_['pr'], head=tuple_['head'], context=CONTEXT,
                   trusted_revision=tuple_['revision'])
    marker = re.match(r'<!-- mergepath-generation:v1 (.*?) -->', newest.get('output', {}).get('summary', ''))
    require(newest['id'] == tuple_['generation'] and newest['status'] == 'completed'
            and newest['conclusion'] == 'success' and marker and json.loads(marker[1]) == binding,
            'publisher generation is not current genuine clearance')
    return [r for r in runs if r.get('external_id') and r['status'] == 'completed'
            and r['conclusion'] == 'failure' and r['head_sha'] == tuple_['head']]


def recover(repo, tuple_):
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo), 'invalid repository')
    require(type(tuple_['pr']) is int and tuple_['pr'] > 0
            and type(tuple_['generation']) is int and tuple_['generation'] > 0
            and all(isinstance(tuple_[k], str) and SHA.fullmatch(tuple_[k])
                    for k in ['head', 'base', 'revision']), 'invalid recovery nomination')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    require(revision == tuple_['revision'], 'checkout is not the nominated trusted revision')
    pr = live_pair(repo, tuple_)
    native = current_generation(repo, tuple_)
    for check in native:
        match = re.fullmatch(rf'https://github\.com/{re.escape(repo)}/actions/runs/([1-9][0-9]*)/job/([1-9][0-9]*)', check.get('details_url', ''))
        require(match is not None, 'native check has no matching Actions run/job URL')
        run_id, job_id = map(int, match.groups())
        run = api(repo, f'actions/runs/{run_id}')
        require(run['id'] == run_id and run['repository']['id'] == pr['base']['repo']['id']
                and run['path'] == WORKFLOW and run['event'] in
                ['pull_request', 'pull_request_review', 'pull_request_review_comment']
                and run['head_repository']['id'] == pr['head']['repo']['id']
                and run['head_branch'] == pr['head']['ref'], 'unrelated native workflow source')
        if run['status'] != 'completed' or run['run_attempt'] != 1:
            continue  # One automatic retry only; an actual second failure remains blocked.
        if run['head_sha'] == tuple_['head']:
            require(any(p.get('number') == tuple_['pr']
                        and p.get('head', {}).get('sha') == tuple_['head']
                        and p.get('base', {}).get('sha') == tuple_['base']
                        for p in run.get('pull_requests', [])),
                    'direct-head source has no matching immutable PR/head/base association')
        else:
            commit = api(repo, f'git/commits/{run["head_sha"]}')
            require(commit['sha'] == run['head_sha'] and
                    [p['sha'] for p in commit['parents']] == [tuple_['base'], tuple_['head']],
                    'native source does not bind this full head/base')
        pages = api(repo, f'actions/runs/{run_id}/attempts/1/jobs?per_page=100', paginate=True)
        jobs = [j for page in pages for j in page['jobs'] if j['id'] == job_id]
        require(len(jobs) == 1 and jobs[0]['run_id'] == run_id
                and jobs[0]['name'] == CONTEXT and jobs[0]['status'] == 'completed'
                and jobs[0]['conclusion'] == 'failure'
                and jobs[0]['check_run_url'] == f'https://api.github.com/repos/{repo}/check-runs/{check["id"]}',
                'native job/check binding is incomplete')
        # Re-evaluate the trusted predicate. Nomination/green API state alone
        # grants no rerun, and this helper never writes a success status.
        verdict = subprocess.run(['bash', 'scripts/merge-clearance-gate.sh', str(tuple_['pr']), repo],
                                 capture_output=True, text=True, timeout=180)
        require(verdict.returncode == 0 and 'Merge clearance: PASS' in verdict.stdout,
                'real clearance is no longer established')
        live_pair(repo, tuple_)
        require(any(r['id'] == check['id'] for r in current_generation(repo, tuple_)),
                'native check was superseded')
        latest = api(repo, f'actions/runs/{run_id}')
        require(latest['run_attempt'] == 1 and latest['status'] == 'completed'
                and latest['head_sha'] == run['head_sha'] and latest['workflow_id'] == run['workflow_id'],
                'native run changed before rerun')
        # No ambiguous POST retry. A later event observes the new attempt;
        # the required native context remains blocking until it really passes.
        api(repo, f'actions/jobs/{job_id}/rerun', method='POST')
        print(f'Requested actual native MCG rerun: PR #{tuple_["pr"]} {tuple_["head"]} run {run_id} attempt 1 job {job_id}')


def main():
    tuples = json.loads(sys.argv[2])
    require(isinstance(tuples, list), 'recovery nominations must be a list')
    failed = False
    for tuple_ in tuples:
        try:
            recover(sys.argv[1], tuple_)
        except (ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            print(f'::warning::Native recovery refused: {error}', file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
