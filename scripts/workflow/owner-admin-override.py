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
from pathlib import Path

MARKER = '<!-- mergepath-owner-admin-override:v1 -->'
BOT = 'chatgpt-codex-connector[bot]'
FIELDS = {'version', 'pr_url', 'head_sha', 'authorized_at', 'authorization_quote',
          'allow_needs_human_review', 'allow_codex_inflight'}


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


def merge_args(argv):
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
            return None
    if not args or args.pop(0) != 'merge':
        return None
    admin = False
    selector = None
    heads = []
    while args:
        flag = args.pop(0)
        if flag in ('--admin', '--admin=true', '--admin=True', '--admin=TRUE', '--admin=t', '--admin=T', '--admin=1'):
            admin = True
        elif flag in ('--admin=false', '--admin=False', '--admin=FALSE', '--admin=f', '--admin=F', '--admin=0'):
            pass
        elif flag in ('--repo', '-R', '--match-head-commit', '--body', '-b', '--body-file', '-F', '--subject', '-t', '--author-email', '-A'):
            if not args:
                raise ValueError(f'{flag} needs a value')
            value = args.pop(0)
            if flag in ('--repo', '-R'):
                repo = value
            elif flag == '--match-head-commit':
                heads.append(value)
        elif flag.startswith('--match-head-commit='):
            heads.append(flag.split('=', 1)[1])
        elif flag.startswith('--repo='):
            repo = flag.split('=', 1)[1]
        elif flag.startswith('-R') and len(flag) > 2:
            repo = flag[2:].lstrip('=')
        elif not flag.startswith('-') and selector is None:
            selector = flag
    return (selector, repo, heads) if admin else None


def response_anchor(body, head):
    """Provider response observation; this does not grant review clearance."""
    fields = [line for line in body.splitlines() if re.search(r'(?i)reviewed commit', line)]
    if len(fields) != 1:
        return False
    match = re.fullmatch(r'\s*(?:\*\*)?Reviewed commit:?(?:\*\*)?:?\s*`?([0-9a-f]{7,40})`?\s*', fields[0], re.I)
    return bool(match and head.startswith(match[1].lower()))


def codex_inflight(comments, reviews, inline, head, author, at=None, bot=BOT):
    """Observe unanswered requests without granting response clearance."""
    def visible(item, field):
        return at is None or (item.get(field, '') <= at
                              and item.get('updated_at', item.get(field, '')) <= at)

    comments = [comment for comment in comments if visible(comment, 'created_at')]
    reviews = [review for review in reviews if visible(review, 'submitted_at')]
    inline = [comment for comment in inline if visible(comment, 'created_at')]
    requests = [comment['created_at'] for comment in comments
                if comment.get('user', {}).get('login') == author
                and comment.get('body', '').strip() == '@codex review']
    responses = [review['submitted_at'] for review in reviews
                 if review.get('user', {}).get('login') == bot and review.get('commit_id') == head
                 and (review.get('body', '').strip() or not any(comment.get('pull_request_review_id') == review.get('id') for comment in inline)
                      or any(comment.get('pull_request_review_id') == review.get('id') and not comment.get('in_reply_to_id')
                             and comment.get('user', {}).get('login') == bot for comment in inline))]
    responses += [comment['created_at'] for comment in comments
                  if comment.get('user', {}).get('login') == bot and response_anchor(comment.get('body', ''), head)]
    if requests and (not responses or max(requests) >= max(responses)):
        return True
    for comment in comments:
        if comment.get('user', {}).get('login') != bot or '<!-- codex-pull-request-review-summary -->' not in comment.get('body', ''):
            continue
        row = re.search(r'Code Review[^\n]*\|[^\n]*Running[^\n]*\|\s*`([0-9a-f]{7,40})`', comment['body'])
        if row and head.startswith(row[1]) and (not responses or comment.get('updated_at', comment['created_at']) >= max(responses)):
            return True
    return False


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


def prepare(argv):
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
    pr = gh(*query, '--json', 'url,headRefOid,baseRefOid,labels,statusCheckRollup')
    url, head = pr['url'], pr['headRefOid']
    match = re.fullmatch(r'https://github.com/([^/]+/[^/]+)/pull/([1-9][0-9]*)', url)
    if not match:
        raise ValueError('admin recording supports the verified github.com author identity only')
    if heads != [head] or os.environ.get('BREAK_GLASS_ADMIN') != f'{url}@{head}':
        raise ValueError('admin merge needs the exact PR@full-head authorization and one --match-head-commit')
    record = validate(json.loads(os.environ.get('MERGEPATH_OWNER_ADMIN_AUTHORIZATION', 'null')),
                      url, head, dt.datetime.now(dt.timezone.utc))
    labels = {label['name'] for label in pr['labels']}
    if labels & {'human-hold', 'policy-violation'}:
        raise ValueError('human-hold and policy-violation require human label removal')
    repository, number = match.groups()
    base = pr['baseRefOid']
    bot = governing_bot(gh, repository, base)

    def pages(endpoint):
        result = gh('api', '--paginate', '--slurp', f'repos/{repository}/{endpoint}')
        if not isinstance(result, list) or not all(isinstance(page, list) for page in result):
            raise ValueError('GitHub returned incomplete paginated state')
        return [item for page in result for item in page]

    events = pages(f'issues/{number}/timeline')
    fresh_escalation = any(event.get('event') == 'labeled' and event.get('label', {}).get('name') == 'needs-human-review'
                           and event['created_at'] >= record['authorized_at'] for event in events)
    if fresh_escalation and not record['allow_needs_human_review']:
        raise ValueError('a later needs-human-review escalation requires explicit owner authorization')
    comments = pages(f'issues/{number}/comments')
    reviews = pages(f'pulls/{number}/reviews')
    inline = pages(f'pulls/{number}/comments')
    inflight = codex_inflight(comments, reviews, inline, head, os.environ['GH_AS_AUTHOR_RECORD_IDENTITY'], bot=bot)
    if inflight and not record['allow_codex_inflight']:
        raise ValueError('an unanswered Codex request requires explicit owner authorization')
    red = sorted({check.get('name') or check.get('context') or '<unnamed>' for check in pr['statusCheckRollup']
                  if (check.get('conclusion') or check.get('state')) not in ('SUCCESS', 'NEUTRAL', 'SKIPPED')})
    published = {**record, 'observed_red_gates': red, 'observed_codex_inflight': inflight,
                 'observed_fresh_escalation': fresh_escalation}
    body = MARKER + '\n```json\n' + json.dumps(published, sort_keys=True, indent=2) + '\n```'
    existing = [comment for comment in comments if comment.get('body') == body
                and comment.get('user', {}).get('login') == os.environ['GH_AS_AUTHOR_RECORD_IDENTITY']]
    posted = existing[-1] if existing else gh('api', f'repos/{repository}/issues/{number}/comments', '-f', f'body={body}')
    confirmed = gh('api', f'repos/{repository}/issues/comments/{posted["id"]}')
    if confirmed.get('body') != body or confirmed.get('user', {}).get('login') != os.environ['GH_AS_AUTHOR_RECORD_IDENTITY']:
        raise ValueError('owner override comment failed author/body readback')
    # A branch push after this read is rejected by GitHub's writer precondition.
    final_pr = gh(*query, '--json', 'url,headRefOid,baseRefOid,labels')
    if {label['name'] for label in final_pr['labels']} & {'human-hold', 'policy-violation'}:
        raise ValueError('human-hold and policy-violation require human label removal')
    if 'needs-human-review' in {label['name'] for label in final_pr['labels']} and not record['allow_needs_human_review']:
        raise ValueError('needs-human-review requires explicit owner authorization')
    if final_pr['headRefOid'] != head or final_pr['baseRefOid'] != base:
        raise ValueError('PR head or governing base changed after recording the owner instruction')
    if not record['allow_codex_inflight'] and codex_inflight(
            pages(f'issues/{number}/comments'), pages(f'pulls/{number}/reviews'),
            pages(f'pulls/{number}/comments'), head, os.environ['GH_AS_AUTHOR_RECORD_IDENTITY'], bot=bot):
        raise ValueError('a later unanswered Codex request requires explicit owner authorization')
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
            observed = {'observed_red_gates', 'observed_codex_inflight', 'observed_fresh_escalation'}
            if not isinstance(record, dict) or set(record) != FIELDS | observed:
                continue
            if (type(record['observed_codex_inflight']) is not bool
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
            if (record['observed_codex_inflight'] or codex_inflight(
                    payload['comments'], payload['reviews'], payload['inline_comments'],
                    pr['head']['sha'], author, pr['merged_at'], bot=payload.get('codex_bot_login', BOT))) and not record['allow_codex_inflight']:
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
        elif sys.argv[1:2] == ['prepare']:
            prepare(sys.argv[2:])
        else:
            raise ValueError('usage: owner-admin-override.py prepare <gh argv...> | validate <URL> <HEAD> | audit < JSON')
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f'BLOCKED: owner admin authorization: {error}', file=sys.stderr)
        sys.exit(2)
