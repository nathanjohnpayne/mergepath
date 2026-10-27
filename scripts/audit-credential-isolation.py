#!/usr/bin/env python3
"""Read-only audit of merge-authority secret placement (#1547)."""
import argparse
import json
import re
import subprocess
from urllib.parse import quote

AUTHORITY = {'AUTHOR_MERGE_TOKEN', 'REVIEWER_ASSIGNMENT_TOKEN', 'CLAUDE_PAT', 'CODEX_PAT',
             'MERGE_QUEUE_POLICY_TOKEN', 'MERGE_QUEUE_SOURCE_TOKEN',
             'CURSOR_PAT', 'OP_SERVICE_ACCOUNT_TOKEN', 'BRANCH_PROTECTION_AUDIT_TOKEN', 'CI_ACTOR_TOKEN',
             'DEPENDABOT_REVIEWER_TOKEN'}


def deployment_policy(environment):
    """Distinguish an explicitly unrestricted policy from unreadable schema."""
    if 'deployment_branch_policy' not in environment:
        raise ValueError('deployment branch policy metadata is unavailable')
    policy = environment['deployment_branch_policy']
    if policy is not None and (not isinstance(policy, dict)
            or any(type(policy.get(field)) is not bool for field in ('protected_branches', 'custom_branch_policies'))):
        raise ValueError('deployment branch policy metadata is malformed')
    return policy


def assess(repo_secrets, environment, policies, branch, organization_secrets=None,
           environment_secrets=None, expected_secrets=None):
    """Return drift; malformed or incomplete observations are infrastructure.

    With expected_secrets, the environment must hold exactly those secret
    names (#2729: `dependabot-reviewer` holds DEPENDABOT_REVIEWER_TOKEN and
    nothing else). Only the expected names, fixed by the caller, are ever
    reported; other observed names are counted, never echoed. That mode also
    requires an unattended environment: a required-reviewers rule or a
    non-zero wait timer would stall the job that reads the secret.
    """
    if not isinstance(repo_secrets, list) or not all(isinstance(item, dict) and isinstance(item.get('name'), str) for item in repo_secrets):
        raise ValueError('repository secret metadata is malformed')
    organization_secrets = [] if organization_secrets is None else organization_secrets
    if not isinstance(organization_secrets, list) or not all(isinstance(item, dict) and isinstance(item.get('name'), str) for item in organization_secrets):
        raise ValueError('organization secret metadata is malformed')
    if not isinstance(policies, list) or not all(isinstance(item, dict) and isinstance(item.get('name'), str) and item.get('type') in ('branch', 'tag') for item in policies):
        raise ValueError('deployment branch policies are malformed')
    drift = []
    # Observations select fixed labels; no observed secret metadata is emitted.
    exposed = sorted(name for name in AUTHORITY for item in repo_secrets if item['name'] == name)
    if exposed:
        drift.append('Repository-scoped authority credentials: ' + ', '.join(exposed))
    exposed = sorted(name for name in AUTHORITY for item in organization_secrets if item['name'] == name)
    if exposed:
        drift.append('Organization-shared authority credentials: ' + ', '.join(exposed))
    if environment is None:
        return drift + ['The protected credential environment is missing']
    if not isinstance(environment, dict) or type(environment.get('can_admins_bypass')) is not bool:
        raise ValueError('environment bypass metadata is unavailable')
    if environment['can_admins_bypass']:
        drift.append('The protected credential environment permits admin bypass')
    policy = deployment_policy(environment)
    if policy != {'protected_branches': False, 'custom_branch_policies': True}:
        drift.append('The credential environment must use a custom branch policy')
    if not policies or any(item['name'] != branch or item['type'] != 'branch' for item in policies):
        drift.append(f'The credential environment must permit only the literal default branch {branch}')
    if expected_secrets is not None:
        if not isinstance(environment_secrets, list) or not all(isinstance(item, dict) and isinstance(item.get('name'), str) for item in environment_secrets):
            raise ValueError('environment secret metadata is malformed')
        held = [item['name'] for item in environment_secrets]
        # Fixed labels again: a missing name is reported from AUTHORITY, never
        # from the caller's or the API's strings (main() restricts
        # expected_secrets to AUTHORITY names).
        missing = sorted(name for name in AUTHORITY if name in expected_secrets and name not in held)
        if missing:
            drift.append('The credential environment lacks: ' + ', '.join(missing))
        others = sum(1 for name in held if name not in expected_secrets)
        if others:
            drift.append(f'The credential environment holds {others} secret(s) besides the expected ones')
        # GitHub omits protection_rules on an environment that has none.
        rules = environment.get('protection_rules', [])
        if not isinstance(rules, list) or not all(isinstance(rule, dict) and isinstance(rule.get('type'), str) for rule in rules):
            raise ValueError('environment protection rules are malformed')
        if any(rule['type'] == 'required_reviewers' for rule in rules):
            drift.append('The credential environment requires reviewers, which stalls its job')
        for rule in rules:
            if rule['type'] == 'wait_timer':
                if type(rule.get('wait_timer')) is not int:
                    raise ValueError('environment wait timer is malformed')
                if rule['wait_timer'] > 0:
                    drift.append('The credential environment has a wait timer, which delays its job')
    return drift


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--branch', required=True)
    parser.add_argument('--environment', default='merge-queue-policy')
    parser.add_argument('--expect-secrets', metavar='NAME[,NAME...]',
                        help='also require the environment to hold exactly these secret names')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('--repo must be owner/repository')
    expected = None
    if args.expect_secrets is not None:
        expected = sorted(set(args.expect_secrets.split(',')))
        if not all(name in AUTHORITY for name in expected):
            parser.error('--expect-secrets takes authority credential names: ' + ', '.join(sorted(AUTHORITY)))

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
        repository = api(root)
        if (len(repository) != 1 or not isinstance(repository[0], dict)
                or not isinstance(repository[0].get('owner'), dict)
                or repository[0]['owner'].get('type') not in ('User', 'Organization')):
            raise ValueError('repository owner metadata is unavailable')
        organization_secrets = (items(root + '/actions/organization-secrets?per_page=100', 'secrets')
                                if repository[0]['owner']['type'] == 'Organization' else [])
        confirmed_missing_environment = False
        try:
            environments = api(root + '/environments/' + env)
        except subprocess.CalledProcessError as error:
            if not re.search(r'\(HTTP 404\)', error.stderr or ''):
                raise
            # A 404 alone can conceal a permission failure. Confirm absence
            # against the complete, readable environment inventory.
            inventory = items(root + '/environments?per_page=100', 'environments')
            if not all(isinstance(item, dict) and isinstance(item.get('name'), str) for item in inventory):
                raise ValueError('environment inventory is malformed')
            if any(item['name'].casefold() == args.environment.casefold() for item in inventory):
                raise
            environments = [None]
            confirmed_missing_environment = True
        if confirmed_missing_environment:
            drift = assess(secrets, None, [], args.branch, organization_secrets)
            print(json.dumps({'repo': args.repo, 'environment': args.environment,
                              'status': 'DRIFT', 'drift': drift}))
            return 3
        if len(environments) != 1 or not isinstance(environments[0], dict):
            raise ValueError('environment metadata must be one object')
        # GitHub returns 404 for this endpoint when the environment has no
        # custom branch policy. The environment object already proves that
        # drift; do not misclassify the expected 404 as an auth outage.
        policy = deployment_policy(environments[0])
        policies = (items(root + '/environments/' + env + '/deployment-branch-policies?per_page=100', 'branch_policies')
                    if isinstance(policy, dict) and policy.get('custom_branch_policies') is True else [])
        environment_secrets = (items(root + '/environments/' + env + '/secrets?per_page=100', 'secrets')
                               if expected is not None else None)
        drift = assess(secrets, environments[0], policies, args.branch, organization_secrets,
                       environment_secrets, expected)
        print(json.dumps({'repo': args.repo, 'environment': args.environment,
                          'status': 'DRIFT' if drift else 'PASS', 'drift': drift}))
        return 3 if drift else 0
    except (ValueError, TypeError, OSError, subprocess.CalledProcessError) as error:
        # No secret values are requested. Do not print a CLI environment or
        # command debug dump on an authentication failure.
        print(json.dumps({'repo': args.repo, 'status': 'ERROR', 'reason': str(error)}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
