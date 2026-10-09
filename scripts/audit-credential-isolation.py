#!/usr/bin/env python3
"""Read-only audit of merge-authority secret placement (#1547)."""
import argparse
import json
import re
import subprocess
from urllib.parse import quote

AUTHORITY = {'AUTHOR_MERGE_TOKEN', 'REVIEWER_ASSIGNMENT_TOKEN', 'CLAUDE_PAT', 'CODEX_PAT',
             'MERGE_QUEUE_POLICY_TOKEN', 'MERGE_QUEUE_SOURCE_TOKEN',
             'CURSOR_PAT', 'OP_SERVICE_ACCOUNT_TOKEN', 'BRANCH_PROTECTION_AUDIT_TOKEN', 'CI_ACTOR_TOKEN'}


def assess(repo_secrets, environment, policies, branch):
    """Return drift; malformed or incomplete observations are infrastructure."""
    if not isinstance(repo_secrets, list) or not all(isinstance(item, dict) and isinstance(item.get('name'), str) for item in repo_secrets):
        raise ValueError('repository secret metadata is malformed')
    if not isinstance(environment, dict) or type(environment.get('can_admins_bypass')) is not bool:
        raise ValueError('environment bypass metadata is unavailable')
    if not isinstance(policies, list) or not all(isinstance(item, dict) and isinstance(item.get('name'), str) and item.get('type') in ('branch', 'tag') for item in policies):
        raise ValueError('deployment branch policies are malformed')
    drift = []
    exposed = sorted(item['name'] for item in repo_secrets if item['name'] in AUTHORITY)
    if exposed:
        drift.append('Repository-scoped authority credentials: ' + ', '.join(exposed))
    if environment['can_admins_bypass']:
        drift.append('The protected credential environment permits admin bypass')
    policy = environment.get('deployment_branch_policy')
    if policy != {'protected_branches': False, 'custom_branch_policies': True}:
        drift.append('The credential environment must use a custom branch policy')
    if not policies or any(item['name'] != branch or item['type'] != 'branch' for item in policies):
        drift.append(f'The credential environment must permit only the literal default branch {branch}')
    return drift


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--branch', required=True)
    parser.add_argument('--environment', default='merge-queue-policy')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('--repo must be owner/repository')

    def api(endpoint):
        result = subprocess.run(['gh', 'api', '--paginate', '--slurp', endpoint], check=True,
                                capture_output=True, text=True)
        pages = json.loads(result.stdout)
        if not isinstance(pages, list) or not pages:
            raise ValueError(f'{endpoint} returned no pages')
        return pages

    def items(endpoint, key):
        pages = api(endpoint)
        if not all(isinstance(page, dict) and isinstance(page.get(key), list) and type(page.get('total_count')) is int for page in pages):
            raise ValueError(f'{endpoint} returned malformed paginated metadata')
        rows = [row for page in pages for row in page[key]]
        if len(rows) != pages[0]['total_count'] or any(page['total_count'] != len(rows) for page in pages):
            raise ValueError(f'{endpoint} returned incomplete secret/policy metadata')
        return rows

    root = f'repos/{args.repo}'
    env = quote(args.environment, safe='')
    try:
        secrets = items(root + '/actions/secrets?per_page=100', 'secrets')
        environments = api(root + '/environments/' + env)
        if len(environments) != 1:
            raise ValueError('environment metadata must be one object')
        # GitHub returns 404 for this endpoint when the environment has no
        # custom branch policy. The environment object already proves that
        # drift; do not misclassify the expected 404 as an auth outage.
        policy = environments[0].get('deployment_branch_policy')
        policies = (items(root + '/environments/' + env + '/deployment-branch-policies?per_page=100', 'branch_policies')
                    if isinstance(policy, dict) and policy.get('custom_branch_policies') is True else [])
        drift = assess(secrets, environments[0], policies, args.branch)
        print(json.dumps({'repo': args.repo, 'environment': args.environment,
                          'status': 'DRIFT' if drift else 'PASS', 'drift': drift}))
        return 3 if drift else 0
    except (ValueError, TypeError, subprocess.CalledProcessError) as error:
        # No secret values are requested. Do not print a CLI environment or
        # command debug dump on an authentication failure.
        print(json.dumps({'repo': args.repo, 'status': 'ERROR', 'reason': str(error)}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
