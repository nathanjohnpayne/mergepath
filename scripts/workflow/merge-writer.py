#!/usr/bin/env python3
"""Fresh ordinary-merge clearance at the verified author writer (#1609).

The installed launcher and operator toolchain are trusted. Checker code is
loaded from an immutable target-default commit, never the candidate checkout.
This is a client snapshot: GitHub fences the head, not comment generations.
"""
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('owner_override', Path(__file__).with_name('owner-admin-override.py'))
OWNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OWNER)
SHA = re.compile(r'[0-9a-f]{40}')
URL = re.compile(r'https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)')
CODE_FILES = {'scripts/merge-clearance-gate.sh', 'scripts/codex-review-check.sh',
              'scripts/hooks/gh-pr-guard.sh', '.github/review-policy.yml'}
CODE_DIRS = ('scripts/lib/', 'scripts/workflow/')
TIMEOUT = 300


def clean_environment():
    # Explicit transport/runtime values only. No inherited checker/config/skip,
    # shell startup, Python/Node injection, Git redirects or exported functions.
    names = ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'GH_TOKEN',
             'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_CONFIG_DIR',
             'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'SSL_CERT_FILE')
    return {key: os.environ[key] for key in names if key in os.environ}


def trusted_tools(argv):
    directories = os.environ.get('PATH', '').split(os.pathsep)
    for directory in directories:
        path = Path(directory).resolve()
        if not directory or not Path(directory).is_absolute() or path == ROOT or ROOT in path.parents:
            raise ValueError('toolchain PATH must be absolute and outside the candidate checkout')
    tools = {name: shutil.which(name) for name in ('gh', 'bash', 'python3', 'jq', 'node', 'git')}
    tools['gh'] = shutil.which(argv[0])
    for name, value in tools.items():
        if not value or not Path(value).is_absolute() or ROOT in Path(value).resolve().parents:
            raise ValueError(f'trusted operator toolchain is missing {name}')
    return tools


def extract_code(archive, destination):
    seen = set()
    archive_root = None
    total = 0
    archive_total = 0
    entries = 0
    with tarfile.open(fileobj=archive, mode='r:*') as bundle:
        for entry in bundle:
            entries += 1
            archive_total += entry.size
            if entries > 20000 or archive_total > 256 * 1024 * 1024:
                raise ValueError('trusted source archive exceeds its traversal bound')
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts or not path.parts:
                raise ValueError('unsafe trusted archive path')
            if archive_root is None:
                archive_root = path.parts[0]
            if path.parts[0] != archive_root:
                raise ValueError('trusted archive has multiple roots')
            relative = '/'.join(path.parts[1:])
            if relative not in CODE_FILES and not relative.startswith(CODE_DIRS):
                continue
            if entry.isdir():
                continue
            if not entry.isfile() or relative in seen:
                raise ValueError('trusted code must have unique regular archive entries')
            seen.add(relative)
            total += entry.size
            if total > 32 * 1024 * 1024:
                raise ValueError('trusted code archive exceeds the bounded closure size')
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(entry) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            target.chmod(0o755 if entry.mode & 0o111 else 0o644)
    required = CODE_FILES | {'scripts/workflow/resolve_base_policy.sh',
                             'scripts/lib/codex-request-evidence.sh',
                             'scripts/lib/pr-body-contract.mjs'}
    if not required <= seen:
        raise ValueError('trusted default branch lacks the merge-checker closure')


def merge_preflight(argv, command, tools, task):
    environment = clean_environment()
    gh = tools['gh']
    tool_dir = task / '.toolchain'
    tool_dir.mkdir()
    for name, executable in tools.items():
        (tool_dir / name).symlink_to(executable)
    environment['PATH'] = str(tool_dir) + os.pathsep + environment['PATH']

    def read(*args):
        result = subprocess.run([gh, *args], env=environment, text=True,
                                capture_output=True, check=True, timeout=TIMEOUT)
        return json.loads(result.stdout)

    query = ['pr', 'view'] + ([command['selector']] if command['selector'] else [])
    if command['repo']:
        query += ['--repo', command['repo']]
    # Preserve GH_REPO only for initial target resolution; all subsequent reads
    # and the final writer use the canonical URL and explicit repository.
    if 'GH_REPO' in os.environ:
        environment['GH_REPO'] = os.environ['GH_REPO']
    fields = 'url,headRefOid,baseRefOid,baseRefName,state'
    pr = read(*query, '--json', fields)
    environment.pop('GH_REPO', None)
    match = URL.fullmatch(pr.get('url', ''))
    head, base = pr.get('headRefOid', ''), pr.get('baseRefOid', '')
    if not match or not SHA.fullmatch(head) or not SHA.fullmatch(base) or pr.get('state') != 'OPEN':
        raise ValueError('ordinary merge requires a canonical open github.com PR and full head/base')
    if command['heads'] != [head]:
        raise ValueError('ordinary merge requires exactly one matching full --match-head-commit')
    repo, number = match.groups()
    repository = read('api', f'repos/{repo}')
    if repository.get('full_name', '').lower() != repo.lower() or not repository.get('default_branch'):
        raise ValueError('target repository/default branch is unreadable')
    from urllib.parse import quote
    commit = read('api', f'repos/{repo}/commits/{quote(repository["default_branch"], safe="")}')
    source_sha = commit.get('sha', '')
    if not SHA.fullmatch(source_sha):
        raise ValueError('trusted default branch did not resolve to a full commit')
    print(f'merge-writer: {pr["url"]}@{head}; trusted code {repo}@{source_sha}; governing base {base}', file=sys.stderr)
    with tempfile.TemporaryFile() as archive:
        subprocess.run([gh, 'api', f'repos/{repo}/tarball/{source_sha}'],
                       env=environment, stdout=archive, check=True, timeout=TIMEOUT)
        if archive.tell() > 64 * 1024 * 1024:
            raise ValueError('trusted source download exceeds its size bound')
        archive.seek(0)
        extract_code(archive, task)
    resolver = task / 'scripts/workflow/resolve_base_policy.sh'
    policy_result = subprocess.run([tools['bash'], str(resolver), '--repo', repo,
                                   '--base-ref', pr['baseRefName'], '--base-sha', base,
                                   '--default-branch', repository['default_branch'],
                                   '--default-config', str(task / '.github/review-policy.yml'),
                                   '--materialize-default'], env=environment,
                                  cwd=task, text=True, capture_output=True, check=True, timeout=TIMEOUT)
    policy_path = Path(policy_result.stdout.strip())
    try:
        policy = policy_path.read_bytes()
    finally:
        if policy_path != task / '.github/review-policy.yml':
            policy_path.unlink()
    # The guard's on-disk policy must also be governed by the exact PR base.
    (task / '.github/review-policy.yml').write_bytes(policy)
    parser = task / 'scripts/lib/feedback-policy-helpers.sh'
    configured = subprocess.run([tools['bash'], '-c', '. "$1"; policy_yaml_to_json "$2"',
                                '_', str(parser), str(task / '.github/review-policy.yml')],
                               cwd=task, env=environment, capture_output=True,
                               text=True, check=True, timeout=TIMEOUT)
    policy_data = json.loads(configured.stdout)
    if not isinstance(policy_data, dict):
        raise ValueError('governing policy must be an object')
    author = policy_data.get('author_identity')
    if not author or author != os.environ.get('GH_AS_AUTHOR_RECORD_IDENTITY'):
        raise ValueError('verified author differs from the governing base policy')
    normalized = [gh, 'pr', 'merge', pr['url'], '--repo', repo, *command['options']]
    # Existing hook owns CI/merge-state, human stops, reviewer disagreements
    # and native-queue refusal. Scoped existing owner tiebreaks retain their
    # own contract; no caller knob chooses the fresh clearance semantics.
    for name in ('BREAK_GLASS_MERGE_STATE', 'BREAK_GLASS_REVIEW_DISAGREEMENT'):
        if name in os.environ:
            environment[name] = os.environ[name]
    environment.update(GH_AS_AUTHOR_IDENTITY=author, GH_PR_GUARD_EXPECTED_AUTHOR=author,
                       CODEX_CLEARED='1')  # Compatibility with pre-#1609 trusted hooks.
    payload = json.dumps({'tool_input': {'command': shlex.join(['scripts/gh-as-author.sh', '--', *normalized])}})
    subprocess.run([tools['bash'], str(task / 'scripts/hooks/gh-pr-guard.sh')], input=payload,
                   env=environment, cwd=task, text=True, check=True, timeout=TIMEOUT)
    environment.pop('CODEX_CLEARED', None)
    environment.update(MERGE_CLEARANCE_EXPECTED_HEAD_SHA=head,
                       MERGE_CLEARANCE_EXPECTED_BASE_SHA=base,
                       MERGE_CLEARANCE_EXPECTED_BASE_REF=pr['baseRefName'],
                       MERGE_CLEARANCE_MATERIALIZE_DEFAULT_POLICY='true')
    subprocess.run([tools['bash'], str(task / 'scripts/merge-clearance-gate.sh'), number, repo],
                   env=environment, cwd=task, check=True, timeout=TIMEOUT)
    fresh = read('pr', 'view', pr['url'], '--repo', repo, '--json', fields)
    if fresh != pr:
        raise ValueError('PR target/head/base/state changed during final clearance')
    return normalized


def run(marker, argv):
    command = OWNER.merge_command(argv)
    if command and command['action'] == 'deferred':
        raise ValueError('deferred auto-merge is not authorized by a client clearance snapshot')
    if command and command['action'] == 'ordinary':
        tools = trusted_tools(argv)
        with tempfile.TemporaryDirectory(prefix='mergepath-merge-code-') as directory:
            normalized = merge_preflight(argv, command, tools, Path(directory))
            return write(marker, normalized)
    return write(marker, argv)


def write(marker, argv):
    if marker:
        try:
            Path(marker).write_bytes(b'')
        except OSError:
            print('gh-as-author: cannot write the trace marker; refusing the write unrecorded.', file=sys.stderr)
            return 70
    return subprocess.call(argv)


if __name__ == '__main__':
    try:
        sys.exit(run(sys.argv[1], sys.argv[2:]))
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError,
            tarfile.TarError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f'BLOCKED: fresh ordinary merge clearance: {error}', file=sys.stderr)
        sys.exit(2)
