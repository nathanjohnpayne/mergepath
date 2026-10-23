#!/usr/bin/env python3
"""Explicit Actions event policies for the propagated pull_request_target workflows (#2733).

GitHub blocks pull_request_target in affected public repositories from
2026-11-02 unless an applicable Actions event policy explicitly allows it
(https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).
A workflow file cannot opt itself out; the remedy is a repository setting the
owner applies. This tool keeps that setting honest:

  lint              The local workflows that trigger on pull_request_target are
                    exactly REGISTRY, each triggers on exactly its pinned
                    events, and none checks out or fetches candidate code.
  payloads          Print the policy bodies (one per REGISTRY workflow).
  plan --repo R     Read R's repository-level policies and print, for the owner
                    to run, the create or update command for each body.
  verify --repo R   Read back every policy applying to R (inherited included)
                    and R's own copy of each REGISTRY workflow; report whether
                    each workflow would be allowed to run on every event it
                    triggers on.

plan and verify need a token with Administration access on R (the owner's);
reviewer tokens get 404. This tool never writes a setting itself.

Exit codes: 0 ok; 1 a finding (lint failure, or a workflow not verified as
allowed); 2 usage; 3 an API or parse error.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from urllib.parse import quote

API_VERSION = '2026-03-10'
# Each propagated workflow that triggers on pull_request_target, pinned to
# every event it triggers on. An event rule is an allowlist, so a policy
# scoped to one of these paths blocks any event it does not list: adding a
# trigger here means updating the policy on every public consumer first.
REGISTRY = {
    '.github/workflows/dependabot-auto-merge.yml': ['pull_request_target'],
    '.github/workflows/auto-clear-blocking-labels.yml': [
        'pull_request_target', 'workflow_run', 'repository_dispatch', 'schedule'],
    '.github/workflows/merge-queue-authorization.yml': ['pull_request_target'],
}
# The only refs a REGISTRY workflow may check out: trusted base-side code.
SAFE_CHECKOUT_REFS = {
    '${{ github.event.pull_request.base.sha }}',
    '${{ github.event.repository.default_branch }}',
}
# Shell text that can retrieve code: any git command (none of the registered
# workflows runs git in a step, so global options such as `git -C` cannot hide
# a subcommand), gh downloads, archive endpoints, generic HTTP clients and the
# fork's repository coordinates. A tripwire on the class, not a proof that
# candidate code never runs: an arbitrary program can fetch code in ways no
# text check decides. The boundary itself is the base-side checkout.
UNSAFE_RUN = re.compile(
    r'\bgit\b'
    r'|\bgh\s+(pr\s+checkout|repo\s+clone|run\s+download|release\s+download)\b'
    r'|refs/pull/|pull/\$\{\{|tarball|zipball|head\.repo\.|\bcurl\b|\bwget\b')
REPO_RE = re.compile(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')


class ApiError(Exception):
    pass


def policy_name(path):
    return 'Mergepath %s events' % Path(path).stem


def payload(path):
    return {
        'name': policy_name(path),
        'enforcement': 'active',
        'conditions': {'workflow_path': {'include': [path], 'exclude': []}},
        'rules': [{'type': 'restrict_action_events',
                   'parameters': {'allowed_events': list(REGISTRY[path])}}],
    }


# --- workflow parsing -------------------------------------------------------

def load_yaml(text, label):
    """Parse with PyYAML, else mikefarah yq; fail closed when neither works."""
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            return yaml.safe_load(text)
        except yaml.YAMLError as exc:
            raise ApiError('%s: YAML parse error: %s' % (label, exc))
    try:
        out = subprocess.run(['yq', '-o=json', '.', '-'], input=text, capture_output=True,
                             text=True, check=False)
    except FileNotFoundError:
        raise ApiError('%s: neither PyYAML nor yq is available to parse workflows' % label)
    if out.returncode != 0:
        raise ApiError('%s: yq parse error: %s' % (label, out.stderr.strip()))
    return json.loads(out.stdout or 'null')


def trigger_events(doc):
    # PyYAML (YAML 1.1) reads the bare key `on` as boolean true.
    on = None
    if isinstance(doc, dict):
        on = doc['on'] if 'on' in doc else doc.get(True)
    if isinstance(on, str):
        return [on]
    if isinstance(on, list):
        return [str(e) for e in on]
    if isinstance(on, dict):
        return [str(e) for e in on]
    return []


def normalize_expr(value):
    return re.sub(r'\s+', ' ', re.sub(r'\$\{\{\s*(.*?)\s*\}\}', r'${{ \1 }}', str(value).strip()))


def unsafe_patterns(doc):
    """Ways a workflow could run candidate code under its trusted token."""
    found = []
    jobs = doc.get('jobs') if isinstance(doc, dict) else None
    for job_id, job in (jobs or {}).items():
        if not isinstance(job, dict):
            continue
        if 'uses' in job:
            # Local or remote, a called workflow runs with the caller's secrets
            # and this lint does not follow it.
            found.append('job %s calls reusable workflow %s' % (job_id, job['uses']))
        for idx, step in enumerate(job.get('steps') or []):
            if not isinstance(step, dict):
                continue
            where = 'job %s step %d' % (job_id, idx + 1)
            uses = step.get('uses') if isinstance(step.get('uses'), str) else ''
            # GitHub resolves an action's owner/repo case-insensitively.
            action = uses.split('@', 1)[0].lower()
            # The runner passes inputs as upper-cased INPUT_* variables, so an
            # input key matches in any case; keep every spelling, not the last.
            inputs = [(str(k).lower(), v) for k, v in step['with'].items()] \
                if isinstance(step.get('with'), dict) else []
            for key, value in inputs:
                if key == 'allow-unsafe-pr-checkout':
                    found.append('%s sets allow-unsafe-pr-checkout' % where)
                # Without a ref, pull_request_target checks out the default branch.
                elif action == 'actions/checkout' and key == 'ref' \
                        and normalize_expr(value) not in SAFE_CHECKOUT_REFS:
                    found.append('%s checks out ref %s' % (where, value))
                elif action == 'actions/checkout' and key == 'repository' \
                        and normalize_expr(value) != '${{ github.repository }}':
                    found.append('%s checks out repository %s' % (where, value))
            if action == 'actions/download-artifact':
                found.append('%s downloads an artifact' % where)
            run = step.get('run')
            if isinstance(run, str):
                for line in run.splitlines():
                    if line.strip().startswith('#'):
                        continue
                    if UNSAFE_RUN.search(line):
                        found.append('%s runs: %s' % (where, line.strip()))
    return found


def local_workflows(root):
    wf_dir = Path(root) / '.github' / 'workflows'
    return sorted(p for p in wf_dir.glob('*') if p.suffix in ('.yml', '.yaml') and p.is_file())


def lint(root):
    findings = []
    seen = set()
    for wf in local_workflows(root):
        rel = '.github/workflows/' + wf.name
        doc = load_yaml(wf.read_text(), rel)
        events = trigger_events(doc)
        if 'pull_request_target' not in events:
            if rel in REGISTRY:
                findings.append('%s no longer triggers on pull_request_target (triggers: %s): drop it from '
                                'REGISTRY and delete its event policy on every public consumer, or restore '
                                'the trigger' % (rel, sorted(events)))
            continue
        seen.add(rel)
        if rel not in REGISTRY:
            findings.append('%s triggers on pull_request_target but is not in REGISTRY: the default '
                            'policy blocks it in public repositories from 2026-11-02 unless an '
                            'explicit event policy allows it' % rel)
            continue
        if sorted(events) != sorted(REGISTRY[rel]):
            findings.append('%s triggers on %s but REGISTRY pins %s: its event policy allowlist would '
                            'block the difference; update REGISTRY and every public consumer\'s policy'
                            % (rel, sorted(events), sorted(REGISTRY[rel])))
        for item in unsafe_patterns(doc):
            findings.append('%s: %s' % (rel, item))
    for rel in REGISTRY:
        if not (Path(root) / rel).is_file():
            findings.append('%s is in REGISTRY but missing: drop it from REGISTRY and delete its event '
                            'policy on every public consumer, or restore the file' % rel)
    for f in findings:
        print('FAIL: %s' % f)
    if not findings:
        print('PASS: %d pull_request_target workflow(s) match REGISTRY and check out only base-side code: %s'
              % (len(seen), ', '.join(sorted(seen)) or 'none'))
    return 1 if findings else 0


# --- GitHub API -------------------------------------------------------------

def gh_json(args):
    cmd = ['gh', 'api', '-H', 'X-GitHub-Api-Version: %s' % API_VERSION] + args
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        hint = ''
        if 'actions/policies' in ' '.join(args) and 'HTTP 404' in out.stderr:
            hint = ' (policy endpoints need Administration access: use the owner token)'
        raise ApiError('gh api %s failed (exit %d): %s%s' % (' '.join(args), out.returncode,
                                                            out.stderr.strip() or out.stdout.strip(), hint))
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        raise ApiError('gh api %s returned non-JSON: %s' % (' '.join(args), exc))


def list_policies(repo, has_parents):
    pages = gh_json(['--paginate', '--slurp',
                     'repos/%s/actions/policies?has_parents=%s&per_page=100'
                     % (repo, 'true' if has_parents else 'false')])
    policies = []
    for page in pages if isinstance(pages, list) else [pages]:
        if not isinstance(page, dict) or not isinstance(page.get('policies'), list):
            raise ApiError('unexpected policy list shape for %s' % repo)
        policies.extend(page['policies'])
    return policies


def policy_detail(repo, summary):
    href = ((summary.get('_links') or {}).get('self') or {}).get('href') or ''
    path = href.split('https://api.github.com/', 1)[1] if href.startswith('https://api.github.com/') else ''
    if not path:
        path = 'repos/%s/actions/policies/%s' % (repo, summary.get('id'))
    return gh_json([path])


def repo_workflow_events(repo, ref, path):
    """Events of R's own copy of path at ref, or None when R has no such file."""
    # A ref may hold &, # or other URL syntax: encode it in full.
    cmd = ['gh', 'api', 'repos/%s/contents/%s?ref=%s' % (repo, path, quote(ref, safe=''))]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        if 'HTTP 404' in out.stderr or '"status":"404"' in out.stdout:
            return None
        raise ApiError('reading %s@%s from %s failed: %s' % (path, ref, repo, out.stderr.strip()))
    content = json.loads(out.stdout).get('content', '')
    return trigger_events(load_yaml(base64.b64decode(content).decode(), '%s:%s' % (repo, path)))


# --- policy evaluation ------------------------------------------------------

def glob_regex(pattern):
    """GitHub path glob -> regex; None when the pattern uses syntax we do not model."""
    if any(c in pattern for c in '[]{}!'):
        return None
    out, i = '', 0
    while i < len(pattern):
        if pattern.startswith('**', i):
            out, i = out + '.*', i + 2
        elif pattern[i] == '*':
            out, i = out + '[^/]*', i + 1
        elif pattern[i] == '?':
            out, i = out + '[^/]', i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile('^%s$' % out)


def pattern_match(pattern, path):
    """True / False, or None when undecidable."""
    if pattern == path:
        return True
    rx = glob_regex(pattern)
    return None if rx is None else bool(rx.match(path))


def applies(policy, path):
    """Whether a policy's workflow_path condition targets path: True / False / None."""
    cond = (policy.get('conditions') or {}).get('workflow_path')
    if not cond:
        return True  # no condition targets all workflows
    include = cond.get('include') or []
    exclude = cond.get('exclude') or []
    unknown = False
    for pat in exclude:
        m = pattern_match(pat, path)
        if m:
            return False
        unknown = unknown or m is None
    if include and include != ['~ALL']:
        hits = [pattern_match(pat, path) for pat in include]
        if True not in hits:
            return None if None in hits else False
    return None if unknown else True


def evaluate(path, events, policies):
    """(verdict, reasons) for one workflow: ok / blocked / uncovered / unverified."""
    allowed_by, blocked, unverified = [], [], []
    for pol in policies:
        if pol.get('enforcement') != 'active':
            continue  # evaluate and disabled policies never block a run
        label = '"%s" (id %s, %s)' % (pol.get('name'), pol.get('id'), pol.get('source_type') or 'repository')
        hit = applies(pol, path)
        if hit is False:
            continue
        for rule in pol.get('rules') or []:
            kind = rule.get('type')
            if kind == 'restrict_action_events':
                allowed = set((rule.get('parameters') or {}).get('allowed_events') or [])
                missing = [e for e in events if e not in allowed]
                if missing and hit:
                    blocked.append('%s does not allow %s' % (label, ', '.join(missing)))
                elif missing:
                    unverified.append('%s may target this path and does not allow %s' % (label, ', '.join(missing)))
                elif hit and 'pull_request_target' in allowed:
                    allowed_by.append(label)
            else:
                unverified.append('%s has a %s rule this tool does not evaluate' % (label, kind))
    if blocked:
        return 'blocked', blocked
    if unverified:
        return 'unverified', unverified
    if not allowed_by:
        return 'uncovered', ['no active policy explicitly allows pull_request_target; GitHub\'s default '
                             'policy blocks it in affected public repositories from 2026-11-02']
    return 'ok', ['allowed by %s' % ', '.join(allowed_by)]


def verify(repo, ref):
    summaries = list_policies(repo, has_parents=True)
    policies = [policy_detail(repo, s) for s in summaries]
    # The contents API answers a missing ref with the same 404 as a missing
    # file, so resolve the ref first: otherwise a typo reads as "all absent".
    gh_json(['repos/%s/commits/%s' % (repo, quote(ref, safe=''))])
    failed = 0
    print('%s: %d applicable Actions polic%s' % (repo, len(policies), 'y' if len(policies) == 1 else 'ies'))
    for path in REGISTRY:
        events = repo_workflow_events(repo, ref, path)
        if events is None:
            print('ABSENT  %s (not on %s; nothing to allow)' % (path, ref))
            continue
        if 'pull_request_target' not in events:
            # Registry and policy are stale: lint fails the same drift locally.
            print('DRIFT   %s no longer triggers on pull_request_target at %s (triggers: %s)'
                  % (path, ref, ', '.join(events)))
            failed += 1
            continue
        verdict, reasons = evaluate(path, events, policies)
        drift = '' if sorted(events) == sorted(REGISTRY[path]) else ' [events differ from REGISTRY: %s]' % sorted(events)
        print('%-7s %s on %s%s' % (verdict.upper(), path, ', '.join(events), drift))
        for reason in reasons:
            print('          %s' % reason)
        failed += verdict != 'ok'
    return 1 if failed else 0


def plan(repo, out_dir):
    existing = {}
    for pol in list_policies(repo, has_parents=False):
        existing.setdefault(pol.get('name'), []).append(pol.get('id'))
    os.makedirs(out_dir, exist_ok=True)
    print('# Run as the repository owner (Administration: write), one command per line.')
    incomplete = False
    for path in REGISTRY:
        body = payload(path)
        file = os.path.join(out_dir, '%s.%s.json' % (repo.replace('/', '__'), Path(path).stem))
        with open(file, 'w') as fh:
            json.dump(body, fh, indent=2)
            fh.write('\n')
        ids = existing.get(body['name'], [])
        if len(ids) > 1:
            print('# ERROR: %d policies named "%s" (ids %s); resolve by hand' % (len(ids), body['name'], ids))
            incomplete = True
            continue
        method, endpoint = ('PUT', 'repos/%s/actions/policies/%s' % (repo, ids[0])) if ids else \
                           ('POST', 'repos/%s/actions/policies' % repo)
        argv = ['scripts/gh-as-author.sh', '--', 'gh', 'api', '--method', method, '-H',
                'X-GitHub-Api-Version: %s' % API_VERSION, endpoint, '--input', file]
        print(' '.join(shlex.quote(a) for a in argv))
    return 1 if incomplete else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p_lint = sub.add_parser('lint')
    p_lint.add_argument('--root', default=str(Path(__file__).resolve().parents[2]))
    sub.add_parser('payloads')
    p_plan = sub.add_parser('plan')
    p_plan.add_argument('--repo', required=True)
    p_plan.add_argument('--out', required=True, help='directory for the payload files')
    p_verify = sub.add_parser('verify')
    p_verify.add_argument('--repo', required=True)
    p_verify.add_argument('--ref', default='main')
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code == 0 else 2
    if getattr(args, 'repo', None) and not REPO_RE.match(args.repo):
        print('error: --repo must be OWNER/NAME', file=sys.stderr)
        return 2
    try:
        if args.cmd == 'lint':
            return lint(args.root)
        if args.cmd == 'payloads':
            json.dump([payload(p) for p in REGISTRY], sys.stdout, indent=2)
            sys.stdout.write('\n')
            return 0
        if args.cmd == 'plan':
            return plan(args.repo, args.out)
        return verify(args.repo, args.ref)
    except ApiError as exc:
        print('error: %s' % exc, file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
