#!/usr/bin/env python3
"""Bind an operator-recorded owner instruction to one admin merge (#1803)."""
import base64
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

MARKER = '<!-- mergepath-owner-admin-override:v1 -->'
BOT = 'chatgpt-codex-connector[bot]'
FIELDS = {'version', 'pr_url', 'head_sha', 'authorized_at', 'authorization_quote',
          'allow_needs_human_review', 'allow_codex_inflight'}
PR_FIELDS = 'url,headRefOid,baseRefOid,baseRefName,state'
CHECK_QUERY = '''query($owner: String!, $name: String!, $number: Int!, $head: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) { url headRefOid baseRefOid baseRefName state }
    object(expression: $head) { ... on Commit {
      oid
      statusCheckRollup { contexts(first: 100, after: $cursor) {
        totalCount checkRunCount statusContextCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on CheckRun {
            id name status conclusion startedAt completedAt
            checkSuite { id app { id } }
          }
          ... on StatusContext {
            id context state createdAt updatedAt creator { login }
          }
        }
      } }
    } }
  }
}'''
# Wrapper payloads must name a built-in command, not machine-local aliases
# or executable extensions whose expansion can hide an admin merge.
BUILTIN_COMMANDS = {
    'agent-task', 'alias', 'api', 'attestation', 'auth', 'browse', 'cache',
    'codespace', 'completion', 'config', 'discussion', 'gist', 'gpg-key', 'help', 'issue',
    'label', 'licenses', 'org', 'pr', 'preview', 'project', 'release', 'repo',
    'ruleset', 'run', 'search', 'secret', 'skill', 'ssh-key', 'status',
    'variable', 'workflow',
}


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', value):
        raise ValueError('authorization timestamp must be UTC YYYY-MM-DDTHH:MM:SSZ')
    return dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def validate(record, url, head, now):
    if not isinstance(record, dict) or set(record) != FIELDS or type(record['version']) is not int or record['version'] != 1:
        raise ValueError('owner authorization must have the version-1 record fields')
    if record['pr_url'] != url or record['head_sha'] != head or not re.fullmatch('[0-9a-f]{40}', head):
        raise ValueError('owner authorization belongs to a different PR or full head')
    if timestamp(record['authorized_at']) > now:
        raise ValueError('owner authorization is dated in the future')
    if not isinstance(record['authorization_quote'], str) or not record['authorization_quote'].strip():
        raise ValueError('the quoted owner instruction is required')
    for key in ('allow_needs_human_review', 'allow_codex_inflight'):
        if type(record[key]) is not bool:
            raise ValueError(f'{key} must explicitly be true or false')
    return record


def reject_merge_api(args):
    """Keep owner-token API transports from bypassing the scoped merge path."""
    args = list(args)
    endpoint, method, queries = None, None, []
    fields, opaque = False, False
    value_flags = {'-X', '--method', '-f', '--raw-field', '-F', '--field',
                   '-H', '--header', '--input', '--hostname', '-q', '--jq',
                   '-t', '--template', '--cache', '-p', '--preview'}
    while args:
        token = args.pop(0)
        flag, value = token, None
        if token in ('--help', '-h'):
            return
        if token in value_flags:
            if not args:
                raise ValueError('API option needs a value')
            value = args.pop(0)
        elif token.startswith('--') and '=' in token:
            flag, value = token.split('=', 1)
        elif len(token) > 2 and token[:2] in ('-X', '-f', '-F', '-H', '-q', '-t', '-p'):
            flag, value = token[:2], token[2:]
        elif token.startswith('-') and not token.startswith('--') and len(token) > 2:
            raise ValueError('clustered API shorthand is ambiguous; use separate flags for inspectable merge protection')
        if flag in ('-X', '--method'):
            method = value.upper()
        elif flag in ('-f', '--raw-field', '-F', '--field'):
            fields = True
            key, _, content = value.partition('=')
            if key == 'query':
                if flag in ('-F', '--field') and content.startswith('@'):
                    opaque = True
                else:
                    queries.append(content)
            elif key.startswith('query[') or key == 'extensions':
                opaque = True
        elif flag == '--input':
            opaque = True
            fields = True
        elif not token.startswith('-'):
            if endpoint is not None:
                raise ValueError('ambiguous API endpoint')
            endpoint = token
    if endpoint is None:
        return
    # Decode URI spelling before classifying the actual GitHub route. This
    # includes full API URLs and CLI owner/repo placeholder forms.
    for _ in range(3):
        decoded = urllib.parse.unquote(endpoint)
        if decoded == endpoint:
            break
        endpoint = decoded
    path = urllib.parse.urlsplit(endpoint).path.rstrip('/')
    method = method or ('POST' if fields else 'GET')
    if re.search(r'(?:^|/)pulls/[^/]+/merge$', path) and method not in ('GET', 'HEAD'):
        raise ValueError('merge API mutations are forbidden; use the head-pinned PR merge command')
    if path.rsplit('/', 1)[-1] == 'graphql':
        # Files/stdin can change after validation or hide a persisted query.
        # A literal immutable query is the only inspectable wrapper payload.
        if opaque or len(queries) != 1:
            raise ValueError('author GraphQL API calls require one literal query; opaque merge payloads are forbidden')
        # Arming auto-merge or entering the queue merges later without the
        # gates too, so those mutations are refused with the merge itself.
        if re.search(r'\b(mergePullRequest|enablePullRequestAutoMerge|disablePullRequestAutoMerge'
                     r'|addPullRequestToMergeQueue|enqueuePullRequest|dequeuePullRequest)\b', queries[0]):
            raise ValueError('merge API mutations are forbidden; use the head-pinned PR merge command')


def merge_command(argv):
    """Inspect actual argv; option values never become flags or selectors."""
    args = argv[1:]
    repo = None
    while args and args[0] != 'pr':
        flag = args.pop(0)
        if flag in ('--repo', '-R') and args:
            repo = args.pop(0)
        elif flag.startswith('--repo='):
            repo = flag.split('=', 1)[1]
        elif flag.startswith('-R') and len(flag) > 2:
            repo = flag[2:].lstrip('=')
        else:
            if flag == 'api':
                reject_merge_api(args)
            if flag not in BUILTIN_COMMANDS and flag not in ('--help', '--version'):
                raise ValueError('author wrapper requires a literal built-in gh command; aliases and extensions cannot authorize an admin merge')
            return None
    if not args or args.pop(0) != 'pr':
        return None
    while args and args[0] != 'merge':
        flag = args.pop(0)
        if flag in ('--repo', '-R') and args:
            repo = args.pop(0)
        elif flag.startswith('--repo='):
            repo = flag.split('=', 1)[1]
        elif flag.startswith('-R') and len(flag) > 2:
            repo = flag[2:].lstrip('=')
        else:
            if flag.startswith('-'):
                raise ValueError('unsupported option before PR verb; pass repository options explicitly')
            return None
    if not args or args.pop(0) != 'merge':
        return None
    action_flags = {'admin': False, 'auto': False, 'disable-auto': False}
    selector = None
    heads = []
    options = []
    positional = False
    while args:
        flag = args.pop(0)
        if flag == '--' and not positional:
            positional = True
            continue
        if positional or not flag.startswith('-'):
            if selector is not None:
                raise ValueError('merge requires at most one PR selector')
            selector = flag
            continue
        key, equal, attached = flag.partition('=')
        if key in ('--admin', '--auto', '--disable-auto'):
            value = True
            if equal:
                if attached.lower() not in ('true', 't', '1', 'false', 'f', '0'):
                    raise ValueError(f'{key} needs a boolean value')
                value = attached.lower() in ('true', 't', '1')
            action_flags[key[2:]] = value
            options.append(flag)
        elif key in ('--repo', '-R', '--match-head-commit', '--body', '-b', '--body-file', '-F', '--subject', '-t', '--author-email', '-A'):
            if equal:
                value = attached
                spelling = [flag]
            else:
                if not args:
                    raise ValueError(f'{flag} needs a value')
                value = args.pop(0)
                spelling = [flag, value]
            if key in ('--repo', '-R'):
                repo = value
            else:
                options.extend(spelling)
                if key == '--match-head-commit':
                    heads.append(value)
        elif len(flag) > 2 and flag[:2] in ('-R', '-b', '-F', '-t', '-A'):
            value = flag[2:].lstrip('=')
            if flag[:2] == '-R':
                repo = value
            else:
                options.append(flag)
        elif key in ('--squash', '-s', '--merge', '-m', '--rebase', '-r', '--delete-branch', '-d'):
            options.append(flag)
        elif flag in ('--help', '-h'):
            return None
        else:
            raise ValueError(f'unsupported merge option {flag}; use explicit merge flags')
    action = ('retraction' if action_flags['disable-auto'] else
              'deferred' if action_flags['auto'] else
              'admin' if action_flags['admin'] else 'ordinary')
    return {'selector': selector, 'repo': repo, 'heads': heads,
            'action': action, 'options': options}


def merge_args(argv):
    """Historical admin-only interface; the writer shares the full classifier."""
    command = merge_command(argv)
    if command is None or command['action'] != 'admin':
        return None
    return command['selector'], command['repo'], command['heads']


def response_anchor(body, head):
    """Provider response observation; this does not grant review clearance."""
    fields = [line for line in body.splitlines() if re.search(r'(?i)reviewed commit', line)]
    if len(fields) != 1:
        return False
    match = re.fullmatch(r'\s*(?:\*\*)?Reviewed commit:?(?:\*\*)?:?\s*`?([0-9a-f]{7,40})`?\s*', fields[0], re.I)
    return bool(match and head.startswith(match[1].lower()))


def historical_request_ledger(repository, number, head):
    """Use the governing canonical timeline; never infer request heads."""
    script = Path(__file__).resolve().parents[1] / 'codex-review-ledger.sh'
    result = subprocess.run([str(script), '--repo', repository, '--expect-head', head, str(number)],
                            capture_output=True, text=True, check=True, timeout=300)
    return json.loads(result.stdout)


def historical_requests_completed(ledger, comments, head, author, bot, at=None, repository=None):
    """Terminal observation only, with the same observed request generation."""
    try:
        if (not isinstance(ledger, dict) or ledger['head_sha'] != head
                or ledger['author'] != author or ledger['bot'] != bot
                or (repository is not None and ledger['repo'] != repository)):
            return False
        cutoff = timestamp(at) if at is not None else None
        observed = {}
        for comment in comments:
            if comment.get('user', {}).get('login') != author or comment.get('body', '').lower() != '@codex review':
                continue
            identity, created = comment['id'], comment['created_at']
            created_at = timestamp(created)
            if type(identity) is not int or identity <= 0:
                return False
            if cutoff is not None and created_at > cutoff:
                continue
            if comment.get('updated_at', created) != created:
                return False
            if identity in observed and observed[identity] != created:
                return False
            observed[identity] = created
        requests, responses = ledger['requests'], ledger['responses']
        if not observed or not isinstance(requests, list) or not isinstance(responses, list):
            return False
        scoped = []
        for row in requests:
            if (not isinstance(row, dict) or type(row['counted']) is not bool
                    or type(row['id']) is not int or row['id'] <= 0):
                return False
            created_at = timestamp(row['created_at'])
            if cutoff is None or created_at <= cutoff:
                scoped.append(row)
        counted = [row for row in scoped if row['counted']]
        if len(counted) != len(observed) or {row['id']: row['created_at'] for row in counted} != observed:
            return False
        by_id = {row['rid']: row for row in responses}
        if len(by_id) != len(responses):
            return False
        for request in scoped:
            if request['outcome'] != 'attributed' or not request['responses']:
                return False
            for identity in request['responses']:
                response = by_id[identity]
                if (not isinstance(response['anchor'], str) or not re.fullmatch('[0-9a-f]{40}', response['anchor'])
                        or response['tie'] is not False or response['mixed_heads'] is not False
                        or response['anchor_conflict'] is not False
                        or timestamp(response['first_at']) <= timestamp(request['created_at'])
                        or (cutoff is not None and timestamp(response['first_at']) > cutoff)):
                    return False
        return True
    except (KeyError, TypeError, ValueError):
        return False


def substantive_review(review, inline, bot):
    replies = [comment for comment in inline if comment.get('pull_request_review_id') == review.get('id')]
    return bool(review.get('body', '').strip() or not replies
                or any(not comment.get('in_reply_to_id') and comment.get('user', {}).get('login') == bot
                       for comment in replies))


def unanchored_terminal_summary(comment):
    """Recognize only the observed automatic idle UI shape, never a response."""
    body = comment.get('body', '')
    records = re.findall(r'(?m)^<!-- codex-review-state:v1 (.+) -->$', body)
    if len(records) != 1 or body.count('<!-- codex-review-state:') != 1:
        return False

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate state field')
            result[key] = value
        return result

    try:
        state = json.loads(records[0], object_pairs_hook=unique_object)
        expected = {'commit_sha', 'has_any_findings', 'has_unresolved_findings', 'status'}
        if (set(state) != {'code_review', 'security_review'}
                or set(state['code_review']) != expected or set(state['security_review']) != expected):
            return False
        code, security = state['code_review'], state['security_review']
        flags = ((code['has_any_findings'] is False and code['has_unresolved_findings'] is False)
                 or (code['has_any_findings'] is None and code['has_unresolved_findings'] is None))
        if (code['commit_sha'] is not None or code['status'] != 'completed'
                or not flags or any(value is not None for value in security.values())):
            return False
        rows = re.findall(r'(?m)^\|[^\n]*(?:Code Review|Security Review)[^\n]*\|\s*$', body, re.I)
        if len(rows) != 1:
            return False
        row = re.fullmatch(r'\|\s*📝\s*\*\*Code Review\*\*\s*\|\s*✅\s*\*\*Completed\*\*\s*'
                           r'<relative-time datetime="([^"<>]+)">([^<>]+)</relative-time>\s*'
                           r'\|\s*—\s*\|\s*PR opened\s*\|\s*', rows[0])
        if not row:
            return False
        if not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z', row[1]):
            return False
        completed = dt.datetime.fromisoformat(row[1].replace('Z', '+00:00'))
        created = timestamp(comment['created_at'])
        updated = timestamp(comment.get('updated_at', comment['created_at']))
        # GitHub comment timestamps have whole-second precision; UI times may
        # include fractions. Compare in that same finite observation bucket.
        return row[1] == row[2] and created <= completed.replace(microsecond=0) <= updated
    except (KeyError, TypeError, ValueError):
        return False


def codex_inflight(comments, reviews, inline, head, author, at=None, bot=BOT, *, ledger=None, repository=None):
    """Observe unanswered requests without granting response clearance."""
    # Edited author/bot comments no longer prove their pre-merge request/status.
    # Keep that uncertainty blocking instead of deleting possible requests.
    if at is not None and any(comment.get('user', {}).get('login') in (author, bot)
            and comment.get('created_at', '') <= at < comment.get('updated_at', comment.get('created_at', ''))
            for comment in comments):
        return True

    def visible(item, field):
        return at is None or (item.get(field, '') <= at
                              and item.get('updated_at', item.get(field, '')) <= at)

    comments = [comment for comment in comments if visible(comment, 'created_at')]
    reviews = [review for review in reviews if visible(review, 'submitted_at')]
    inline = [comment for comment in inline if visible(comment, 'created_at')]
    requests = [comment['created_at'] for comment in comments
                if comment.get('user', {}).get('login') == author
                and comment.get('body', '').lower() == '@codex review']
    if any(comment.get('user', {}).get('login') == author
           and comment.get('body', '').lower() == '@codex review'
           and comment.get('updated_at', comment.get('created_at')) != comment.get('created_at')
           for comment in comments):
        return True
    def response_times(anchor):
        return ([review['submitted_at'] for review in reviews
                 if review.get('user', {}).get('login') == bot and review.get('commit_id') == anchor
                 and substantive_review(review, inline, bot)]
                + [comment['created_at'] for comment in comments
                   if comment.get('user', {}).get('login') == bot and response_anchor(comment.get('body', ''), anchor)])

    responses = response_times(head)
    summaries = []
    historical_summaries = {}
    known_heads = {head} | {review['commit_id'] for review in reviews
                            if isinstance(review.get('commit_id'), str)
                            and re.fullmatch('[0-9a-f]{40}', review['commit_id'])}
    for comment in comments:
        body = comment.get('body', '')
        if comment.get('user', {}).get('login') != bot or not body.startswith('<!-- codex-pull-request-review-summary -->'):
            continue
        row = re.search(r'(?m)^\|\s*📝\s*\*\*Code Review\*\*\s*\|([^|\n]+)\|\s*`([0-9a-f]{7,40})`\s*\|[^|\n]+\|\s*$', body, re.I)
        if not row:
            if unanchored_terminal_summary(comment):
                continue  # No head association or response-time credit.
            return True  # Unreadable provider status cannot prove idleness.
        if row:
            status = 'completed' if re.search(r'\*\*Completed\*\*', row[1], re.I) else 'running' if re.search(r'\*\*Running\*\*', row[1], re.I) else 'unknown'
            item = (comment.get('updated_at', comment['created_at']), comment.get('id', 0), status)
            anchor = row[2].lower()
            matches = [known for known in known_heads if known.startswith(anchor)]
            if len(matches) > 1:
                return True
            anchor = matches[0] if matches else anchor
            historical_summaries[anchor] = max(item, historical_summaries.get(anchor, item))
            if head.lower().startswith(anchor):
                summaries.append(item)
    for anchor, item in historical_summaries.items():
        if item[2] not in ('running', 'unknown'):
            continue
        terminal = response_times(anchor)
        if not terminal or item[0] >= max(terminal):
            return True
    summary = max(summaries) if summaries else None
    if summary and summary[2] == 'completed':
        responses.append(summary[0])  # Terminal delivery, never merge clearance.
    if requests and (not responses or max(requests) >= max(responses)):
        return not historical_requests_completed(ledger, comments, head, author, bot, at, repository)
    if summary and summary[2] == 'running' and (not responses or summary[0] >= max(responses)):
        return True
    return False


def observe_codex_inflight(comments, reviews, inline, head, author, repository, number, at=None, bot=BOT):
    if not codex_inflight(comments, reviews, inline, head, author, at, bot):
        return False
    # Only a durable historical response warrants the extra canonical read.
    # Summary-only history remains ambiguous; it cannot manufacture a response.
    if not any(review.get('user', {}).get('login') == bot and review.get('commit_id') != head
               and substantive_review(review, inline, bot) for review in reviews) and not any(
               comment.get('user', {}).get('login') == bot and re.search('reviewed commit', comment.get('body', ''), re.I)
               for comment in comments):
        return True
    try:
        ledger = historical_request_ledger(repository, number, head)
        if not isinstance(ledger, dict) or type(ledger.get('pr')) is not int or ledger['pr'] != int(number):
            return True
    except (OSError, ValueError, TypeError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return True
    return codex_inflight(comments, reviews, inline, head, author, at, bot,
                          ledger=ledger, repository=repository)


def governing_bot(gh, repository, base):
    """Read bot identity from the immutable governing policy, never PR bytes."""
    if not isinstance(base, str) or not re.fullmatch('[0-9a-f]{40}', base):
        raise ValueError('governing base SHA is unavailable')
    source = gh('api', f'repos/{repository}/contents/.github/review-policy.yml?ref={base}')
    if not isinstance(source, dict) or source.get('encoding') != 'base64' or not isinstance(source.get('content'), str):
        raise ValueError('governing review policy is unreadable')
    content = base64.b64decode(''.join(source['content'].split()), validate=True).decode('utf-8')
    helper = Path(__file__).resolve().parents[1] / 'lib/feedback-policy-helpers.sh'
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as policy_file:
        policy_file.write(content)
        policy_file.flush()
        result = subprocess.run(['/bin/bash', '-c', '. "$1"; policy_yaml_to_json "$2"',
                                 '_', str(helper), policy_file.name],
                                text=True, capture_output=True, check=True, timeout=300)
    policy = json.loads(result.stdout)
    if not isinstance(policy, dict):
        raise ValueError('governing review policy must be an object')
    codex = policy.get('codex')
    codex = {} if codex is None else codex
    if not isinstance(codex, dict) or (codex.get('bot_login') is not None and not isinstance(codex['bot_login'], str)):
        raise ValueError('governing codex.bot_login must be a string')
    return codex.get('bot_login') or BOT


def pr_tuple(pr):
    """A scalar target fence shared by CLI reads and every rollup page."""
    if not isinstance(pr, dict) or any(not isinstance(pr.get(key), str) or not pr[key]
                                      for key in PR_FIELDS.split(',')):
        raise ValueError('PR target/head/base/state is unreadable')
    if (pr['state'] != 'OPEN' or not re.fullmatch('[0-9a-f]{40}', pr['headRefOid'])
            or not re.fullmatch('[0-9a-f]{40}', pr['baseRefOid'])):
        raise ValueError('owner authorization requires an open PR with full head/base')
    return tuple(pr[key] for key in PR_FIELDS.split(','))


def check_inventory(gh, repository, number, pr):
    """Read the native rollup completely, without merging same-name producers."""
    expected = pr_tuple(pr)
    owner, name = repository.split('/')
    cursor, cursors, checks, counts = None, set(), {}, None
    while True:
        cursor_arg = ('-F', 'cursor=null') if cursor is None else ('-f', f'cursor={cursor}')
        page = gh('api', 'graphql', '-f', f'query={CHECK_QUERY}', '-f', f'owner={owner}',
                  '-f', f'name={name}', '-F', f'number={number}', '-f', f'head={pr["headRefOid"]}',
                  *cursor_arg)
        if not isinstance(page, dict) or page.get('errors'):
            raise ValueError('GitHub returned an unreadable check inventory page')
        result = page['data']['repository']
        if pr_tuple(result['pullRequest']) != expected:
            raise ValueError('PR target/head/base/state changed during check pagination')
        commit = result['object']
        if not isinstance(commit, dict) or commit.get('oid') != pr['headRefOid']:
            raise ValueError('check inventory belongs to a different commit')
        rollup = commit['statusCheckRollup']
        if rollup is None:
            if cursor is not None:
                raise ValueError('check rollup disappeared during pagination')
            return []
        connection = rollup['contexts']
        if not isinstance(connection, dict):
            raise ValueError('GitHub returned an unreadable check connection')
        observed_counts = tuple(connection[key] for key in ('totalCount', 'checkRunCount', 'statusContextCount'))
        if (any(type(count) is not int or count < 0 for count in observed_counts)
                or observed_counts[0] != sum(observed_counts[1:])
                or (counts is not None and counts != observed_counts)):
            raise ValueError('check inventory counts are malformed or changed during pagination')
        counts = observed_counts
        nodes, info = connection['nodes'], connection['pageInfo']
        if (not isinstance(nodes, list) or len(nodes) > 100 or not isinstance(info, dict)
                or type(info.get('hasNextPage')) is not bool
                or 'endCursor' not in info
                or (info['endCursor'] is not None and not isinstance(info['endCursor'], str))):
            raise ValueError('GitHub returned malformed check pagination state')
        for check in nodes:
            if not isinstance(check, dict) or not isinstance(check.get('id'), str) or not check['id']:
                raise ValueError('check inventory context identity is unreadable')
            if check['id'] in checks:
                raise ValueError('check inventory contains duplicate contexts')
            kind = check.get('__typename')
            if kind == 'CheckRun':
                if (not isinstance(check.get('name'), str) or not isinstance(check.get('status'), str)
                        or not check['status'] or 'conclusion' not in check
                        or (check['conclusion'] is not None and not isinstance(check['conclusion'], str))
                        or any(key not in check or (check[key] is not None and not isinstance(check[key], str))
                               for key in ('startedAt', 'completedAt'))):
                    raise ValueError('check run state is unreadable')
                suite = check.get('checkSuite')
                if (not isinstance(suite, dict) or not isinstance(suite.get('id'), str) or not suite['id']
                        or 'app' not in suite or (suite['app'] is not None and
                            (not isinstance(suite['app'], dict) or not isinstance(suite['app'].get('id'), str)
                             or not suite['app']['id']))):
                    raise ValueError('check run producer is unreadable')
            elif kind == 'StatusContext':
                if (any(not isinstance(check.get(key), str) or not check[key]
                        for key in ('state', 'createdAt', 'updatedAt'))
                        or not isinstance(check.get('context'), str) or 'creator' not in check
                        or (check['creator'] is not None and
                            (not isinstance(check['creator'], dict)
                             or not isinstance(check['creator'].get('login'), str) or not check['creator']['login']))):
                    raise ValueError('commit status state or producer is unreadable')
            else:
                raise ValueError('check inventory contains an unknown context type')
            checks[check['id']] = check
        if len(checks) > counts[0]:
            raise ValueError('check inventory exceeds its reported total')
        if not info['hasNextPage']:
            actual = (len(checks), sum(check['__typename'] == 'CheckRun' for check in checks.values()),
                      sum(check['__typename'] == 'StatusContext' for check in checks.values()))
            if actual != counts:
                raise ValueError('check inventory is incomplete')
            return [checks[key] for key in sorted(checks)]
        cursor = info['endCursor']
        if not nodes or len(checks) >= counts[0] or not cursor or cursor in cursors:
            raise ValueError('check inventory cursor does not advance')
        cursors.add(cursor)


def prepare(argv, *, check_only=False):
    parsed = merge_args(argv)
    if parsed is None:
        return
    executable = shutil.which('gh')
    if not executable or not os.path.isabs(executable):
        raise ValueError('an absolute gh executable is required')

    def gh(*args):
        result = subprocess.run([executable, *args], text=True, capture_output=True, check=True, timeout=300)
        return json.loads(result.stdout)

    selector, repo, heads = parsed
    query = ['pr', 'view'] + ([selector] if selector else [])
    if repo:
        query += ['--repo', repo]
    pr = gh(*query, '--json', PR_FIELDS + ',labels')
    expected = pr_tuple(pr)
    url, head = pr['url'], pr['headRefOid']
    match = re.fullmatch(r'https://github.com/([^/]+/[^/]+)/pull/([1-9][0-9]*)', url)
    if not match:
        raise ValueError('admin recording supports the verified github.com author identity only')
    if heads != [head] or os.environ.get('BREAK_GLASS_ADMIN') != f'{url}@{head}':
        raise ValueError('admin merge needs the exact PR@full-head authorization and one --match-head-commit')
    record = validate(json.loads(os.environ.get('MERGEPATH_OWNER_ADMIN_AUTHORIZATION', 'null')),
                      url, head, dt.datetime.now(dt.timezone.utc))
    def check_pr(current):
        if pr_tuple(current) != expected:
            raise ValueError('PR target/head/base/state changed during owner authorization')
        labels = current['labels']
        if not isinstance(labels, list) or any(not isinstance(label, dict) or not isinstance(label.get('name'), str)
                                             for label in labels):
            raise ValueError('PR blocking labels are unreadable')
        names = {label['name'] for label in labels}
        if names & {'human-hold', 'policy-violation'}:
            raise ValueError('human-hold and policy-violation require human label removal')
        if 'needs-human-review' in names and not record['allow_needs_human_review']:
            raise ValueError('needs-human-review requires explicit owner authorization')

    check_pr(pr)
    repository, number = match.groups()
    # Initial target resolution may use a branch or ambient repository. All
    # subsequent snapshots are bound to the canonical PR GitHub returned.
    query = ['pr', 'view', url, '--repo', repository]
    base = pr['baseRefOid']
    bot = governing_bot(gh, repository, base)
    checks = check_inventory(gh, repository, number, pr)

    def pages(endpoint):
        result = gh('api', '--paginate', '--slurp', f'repos/{repository}/{endpoint}')
        if (not isinstance(result, list) or not result or not all(isinstance(page, list) for page in result)
                or any(not isinstance(item, dict) for page in result for item in page)):
            raise ValueError('GitHub returned incomplete paginated state')
        return [item for page in result for item in page]

    def observations():
        events = pages(f'issues/{number}/timeline')
        escalation = any(event.get('event') == 'labeled' and event.get('label', {}).get('name') == 'needs-human-review'
                         and event['created_at'] >= record['authorized_at'] for event in events)
        if escalation and not record['allow_needs_human_review']:
            raise ValueError('a later needs-human-review escalation requires explicit owner authorization')
        comments = pages(f'issues/{number}/comments')
        reviews = pages(f'pulls/{number}/reviews')
        inline = pages(f'pulls/{number}/comments')
        inflight = observe_codex_inflight(comments, reviews, inline, head,
                                         os.environ['GH_AS_AUTHOR_RECORD_IDENTITY'], repository, number, bot=bot)
        if inflight and not record['allow_codex_inflight']:
            raise ValueError('an unanswered Codex request requires explicit owner authorization')
        return comments, escalation, inflight

    observations()
    if check_inventory(gh, repository, number, pr) != checks:
        raise ValueError('check inventory changed before recording the owner instruction')
    comments, fresh_escalation, inflight = observations()
    check_pr(gh(*query, '--json', PR_FIELDS + ',labels'))
    if check_only:
        return  # Authorization semantics verified without any GitHub write.
    red = sorted({check.get('name') or check.get('context') or '<unnamed>' for check in checks
                  if (check.get('__typename') == 'CheckRun' and check['status'] != 'COMPLETED')
                  or (check.get('conclusion') or check.get('state')) not in ('SUCCESS', 'NEUTRAL', 'SKIPPED')})
    published = {**record, 'observed_codex_bot_login': bot, 'observed_red_gates': red, 'observed_codex_inflight': inflight,
                 'observed_fresh_escalation': fresh_escalation}
    body = MARKER + '\n```json\n' + json.dumps(published, sort_keys=True, indent=2) + '\n```'
    def in_authorization_window(comment):
        try:
            return (timestamp(record['authorized_at']) <= timestamp(comment['created_at'])
                    <= timestamp(comment['updated_at']) <= dt.datetime.now(dt.timezone.utc))
        except (ValueError, KeyError, TypeError):
            return False

    existing = [comment for comment in comments if comment.get('body') == body
                and comment.get('user', {}).get('login') == os.environ['GH_AS_AUTHOR_RECORD_IDENTITY']
                and in_authorization_window(comment)]
    posted = existing[-1] if existing else gh('api', f'repos/{repository}/issues/{number}/comments', '-f', f'body={body}')
    confirmed = gh('api', f'repos/{repository}/issues/comments/{posted["id"]}')
    if (confirmed.get('body') != body or not in_authorization_window(confirmed)
            or confirmed.get('user', {}).get('login') != os.environ['GH_AS_AUTHOR_RECORD_IDENTITY']):
        raise ValueError('owner override comment failed author/body/authorization-order readback')
    if check_inventory(gh, repository, number, pr) != checks:
        raise ValueError('check inventory changed after recording the owner instruction')
    observations()
    # A branch push after this final read is rejected by GitHub's writer
    # precondition; labels, requests and check state remain client snapshots.
    check_pr(gh(*query, '--json', PR_FIELDS + ',labels'))
    print('gh-as-author: recorded scoped owner admin authorization', file=sys.stderr)


def audit(payload):
    pr, author = payload['pr'], payload['author']
    for comment in payload['comments']:
        if comment.get('user', {}).get('login') != author:
            continue
        body = comment.get('body', '')
        match = re.fullmatch(re.escape(MARKER) + r'\n```json\n(.*)\n```', body, re.S)
        if not match:
            continue
        try:
            record = json.loads(match.group(1))
            observed = {'observed_codex_bot_login', 'observed_red_gates', 'observed_codex_inflight', 'observed_fresh_escalation'}
            if not isinstance(record, dict) or set(record) != FIELDS | observed:
                continue
            if (not isinstance(record['observed_codex_bot_login'], str)
                    or not record['observed_codex_bot_login'].strip()
                    or type(record['observed_codex_inflight']) is not bool
                    or type(record['observed_fresh_escalation']) is not bool
                    or not isinstance(record['observed_red_gates'], list)
                    or not all(isinstance(gate, str) for gate in record['observed_red_gates'])):
                continue
            authorization = {key: record[key] for key in FIELDS}
            merged = timestamp(pr['merged_at'])
            validate(authorization, pr['html_url'], pr['head']['sha'], merged)
            posted = timestamp(comment['created_at'])
            updated = timestamp(comment['updated_at'])
            if not timestamp(record['authorized_at']) <= posted <= updated <= merged:
                continue
            if payload.get('hard_hold_at_merge') is True:
                continue
            if (record['observed_fresh_escalation'] or payload.get('needs_human_review_at_merge') is True) and not record['allow_needs_human_review']:
                continue
            match = re.fullmatch(r'https://github.com/([^/]+/[^/]+)/pull/([1-9][0-9]*)', pr['html_url'])
            if not match:
                continue
            if (record['observed_codex_inflight'] or observe_codex_inflight(
                    payload['comments'], payload['reviews'], payload['inline_comments'],
                    pr['head']['sha'], author, *match.groups(), pr['merged_at'],
                    bot=record['observed_codex_bot_login'])) and not record['allow_codex_inflight']:
                continue
            return {'recorded_override': True, 'comment_url': comment['html_url'], 'record': record}
        except (ValueError, KeyError, TypeError):
            continue
    return {'recorded_override': False}


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['validate'] and len(sys.argv) == 4:
            print(json.dumps(validate(json.load(sys.stdin), sys.argv[2], sys.argv[3], dt.datetime.now(dt.timezone.utc))))
        elif sys.argv[1:2] == ['audit']:
            print(json.dumps(audit(json.load(sys.stdin))))
        elif sys.argv[1:2] == ['classify']:
            command = merge_command(sys.argv[2:])
            print(command['action'] if command else '')
        elif sys.argv[1:2] in (['prepare'], ['check']):
            prepare(sys.argv[2:], check_only=sys.argv[1] == 'check')
        else:
            raise ValueError('usage: owner-admin-override.py prepare <gh argv...> | validate <URL> <HEAD> | audit < JSON')
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f'BLOCKED: owner admin authorization: {error}', file=sys.stderr)
        sys.exit(2)
