#!/usr/bin/env python3
"""Normalize provider abbreviations only after trusted GitHub disambiguation."""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time

FIELD = re.compile(r'reviewed commit[^0-9a-z_\r\n]{0,6}([^\r\n]*)', re.I)
HEX = re.compile(r'[0-9a-f]{7,40}', re.I)
QUERY = '''query($owner:String!,$name:String!,$prefix:String!,$branch:String!,$tag:String!){
  repository(owner:$owner,name:$name){
    branch:ref(qualifiedName:$branch){name}
    tag:ref(qualifiedName:$tag){name}
    commit:object(expression:$prefix){__typename oid}
  }
}'''


class Resolver:
    def __init__(self, repository):
        self.owner, self.name = repository.split('/')
        self.gh = shutil.which('gh')
        self.deadline = time.monotonic() + 30
        self.cache = {}

    def resolve(self, prefix):
        prefix = prefix.lower()
        if len(prefix) == 40:
            return prefix
        if prefix in self.cache:
            return self.cache[prefix]
        self.cache[prefix] = None
        remaining = self.deadline - time.monotonic()
        if not self.gh or remaining <= 0 or len(self.cache) > 50:
            return None
        # A hex-named branch/tag could shadow an ambiguous commit prefix.
        # Read both exact refs alongside GitHub's revision resolver and refuse
        # either alias; only an unambiguous Commit object can be normalized.
        argv = [self.gh, 'api', 'graphql', '-f', 'query=' + QUERY,
                '-f', 'owner=' + self.owner, '-f', 'name=' + self.name,
                '-f', 'prefix=' + prefix, '-f', 'branch=refs/heads/' + prefix,
                '-f', 'tag=refs/tags/' + prefix]
        try:
            result = subprocess.run(argv, text=True, capture_output=True,
                                    timeout=min(remaining, 10))
            if result.returncode:
                return None
            payload = json.loads(result.stdout)
            if not isinstance(payload, dict) or payload.get('errors'):
                return None
            repository = payload['data']['repository']
            if repository['branch'] is not None or repository['tag'] is not None:
                return None
            commit = repository['commit']
            oid = commit['oid']
            if (commit['__typename'] == 'Commit' and isinstance(oid, str)
                    and re.fullmatch('[0-9a-f]{40}', oid) and oid.startswith(prefix)):
                self.cache[prefix] = oid
        except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
            pass
        return self.cache[prefix]


def normalize(comments, bot, resolver):
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
