#!/usr/bin/env python3
"""Normalize provider abbreviations only after trusted GitHub disambiguation."""
import argparse
import json
import re
import shutil
import subprocess
import sys

FIELD = re.compile(r'reviewed commit[^0-9a-z_\r\n]{0,6}([^\r\n]*)', re.I)
HEX = re.compile(r'[0-9a-f]{7,40}', re.I)


class Resolver:
    def __init__(self, repository):
        self.owner, self.name = repository.split('/')
        self.gh = shutil.which('gh')
        self.cache = {}

    def prefetch(self, prefixes):
        prefixes = list(dict.fromkeys(value.lower() for value in reversed(list(prefixes)) if len(value) < 40))[:50]
        self.cache = dict.fromkeys(prefixes)
        if not self.gh or not prefixes:
            return
        # A hex-named branch/tag could shadow an ambiguous commit prefix.
        # Resolve the bounded history in one request per scan. Aliases let a
        # prefix-specific GraphQL error refuse that prefix without discarding
        # independently verified objects from the same response.
        fields = []
        for index, prefix in enumerate(prefixes):
            fields.extend([f'b{index}:ref(qualifiedName:"refs/heads/{prefix}"){{name}}',
                           f't{index}:ref(qualifiedName:"refs/tags/{prefix}"){{name}}',
                           f'c{index}:object(expression:"{prefix}"){{__typename oid}}'])
        query = ('query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
                 + ' '.join(fields) + '}}')
        argv = [self.gh, 'api', 'graphql', '-f', 'query=' + query,
                '-f', 'owner=' + self.owner, '-f', 'name=' + self.name]
        try:
            result = subprocess.run(argv, text=True, capture_output=True, timeout=10)
            payload = json.loads(result.stdout)
            if not isinstance(payload, dict):
                return
            errors = payload.get('errors', [])
            if not isinstance(errors, list) or (result.returncode and not errors):
                return
            failed = set()
            for error in errors:
                path = error.get('path') if isinstance(error, dict) else None
                if (not isinstance(path, list) or len(path) < 2 or path[0] != 'repository'
                        or not isinstance(path[1], str) or not re.fullmatch(r'[btc]\d+', path[1])
                        or int(path[1][1:]) >= len(prefixes)):
                    return
                failed.add(int(path[1][1:]))
            repository = payload['data']['repository']
            if not isinstance(repository, dict):
                return
            for index, prefix in enumerate(prefixes):
                if index in failed or repository.get(f'b{index}', {}) is not None or repository.get(f't{index}', {}) is not None:
                    continue
                commit = repository.get(f'c{index}')
                if not isinstance(commit, dict):
                    continue
                oid = commit.get('oid')
                if (commit.get('__typename') == 'Commit' and isinstance(oid, str)
                        and re.fullmatch('[0-9a-f]{40}', oid) and oid.startswith(prefix)):
                    self.cache[prefix] = oid
        except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
            pass

    def resolve(self, prefix):
        prefix = prefix.lower()
        return prefix if len(prefix) == 40 else self.cache.get(prefix)


def normalize(comments, bot, resolver):
    resolver.prefetch(value for comment in comments
                      if (comment.get('user') or {}).get('login') == bot
                      and isinstance(comment.get('body'), str)
                      for field in FIELD.finditer(comment['body'])
                      for value in [field[1].strip('`* \t')]
                      if HEX.fullmatch(value))
    result = []
    for comment in comments:
        body = comment.get('body')
        if ((comment.get('user') or {}).get('login') != bot or not isinstance(body, str)):
            result.append(comment)
            continue
        fields = list(FIELD.finditer(body))
        values = [field[1].strip('`* \t') for field in fields]
        if (not values or len(fields) != len(re.findall('reviewed commit', body, re.I))
                or not all(HEX.fullmatch(value) for value in values)):
            result.append(comment)
            continue
        resolved = [resolver.resolve(value) for value in values]
        if any(value is None for value in resolved) or len(set(resolved)) != 1:
            result.append(comment)
            continue
        # Ephemeral read-side data only; never edit the provider's comment.
        for field, oid in reversed(list(zip(fields, resolved))):
            raw = field[1]
            start = field.start(1) + len(raw) - len(raw.lstrip('`* \t'))
            end = field.end(1) - len(raw) + len(raw.rstrip('`* \t'))
            body = body[:start] + oid + body[end:]
        result.append(dict(comment, body=body))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--bot', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('valid owner/repository required')
    comments = json.load(sys.stdin)
    if not isinstance(comments, list) or not all(isinstance(item, dict) for item in comments):
        raise ValueError('comment array required')
    print(json.dumps(normalize(comments, args.bot, Resolver(args.repo))))


if __name__ == '__main__':
    main()
