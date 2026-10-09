#!/usr/bin/env python3
"""Exercise the real resolver with hermetic trusted-API boundary responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/workflow/resolve-codex-verdict-anchors.py'
BOT = 'chatgpt-codex-connector[bot]'
SHA = 'a' * 40


class ResolutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.payload = {'data': {'repository': {'b0': None, 't0': None,
                        'c0': {'__typename': 'Commit', 'oid': SHA}}}}
        self.status = 0
        stub = self.path / 'gh'
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['ANCHOR_CASE'])
with (p/'calls').open('a') as out: out.write(json.dumps(sys.argv[1:])+'\\n')
print((p/'payload').read_text())
sys.exit(int((p/'status').read_text()))
''')
        stub.chmod(0o755)

    def invoke(self, body=None, bot=BOT):
        bodies = body if isinstance(body, list) else [body or 'Codex Review: didn\'t find any major issues\n**Reviewed commit:** `' + SHA[:10] + '`']
        comments = [{'id': index + 1, 'user': {'login': bot}, 'body': value}
                    for index, value in enumerate(bodies)]
        (self.path/'payload').write_text(json.dumps(self.payload))
        (self.path/'status').write_text(str(self.status))
        result = subprocess.run(['python3', str(SCRIPT), '--repo', 'acme/widget', '--bot', BOT],
                                input=json.dumps(comments), text=True, capture_output=True,
                                env={**os.environ, 'PATH': str(self.path)+os.pathsep+os.environ['PATH'],
                                     'ANCHOR_CASE': str(self.path)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.output = json.loads(result.stdout)
        return comments[0]['body'], self.output[0]['body']

    def test_unique_provider_abbreviation_becomes_full_exact_id(self):
        before, after = self.invoke()
        self.assertNotEqual(before, after)
        self.assertIn('Reviewed commit:** `' + SHA + '`', after)
        calls = [json.loads(line) for line in (self.path/'calls').read_text().splitlines()]
        self.assertIn('refs/heads/' + SHA[:10], calls[0][3])
        self.assertIn('refs/tags/' + SHA[:10], calls[0][3])

    def test_ambiguous_api_result_never_becomes_clearance(self):
        self.payload = {'data': {'repository': {'branch': None, 'tag': None, 'commit': None}},
                        'errors': [{'message': 'Ambiguous commit prefix'}]}
        self.assertEqual(*self.invoke())

    def test_branch_and_tag_aliases_cannot_shadow_a_collision(self):
        for name in ('b0', 't0'):
            self.payload['data']['repository'][name] = {'name': SHA[:10]}
            self.assertEqual(*self.invoke())
            self.payload['data']['repository'][name] = None

    def test_unreadable_or_malformed_api_response_preserves_raw_observation(self):
        for payload in (None, [], {}, {'data': None}, {'data': {'repository': None}}):
            self.payload = payload
            self.assertEqual(*self.invoke())
        self.status = 1
        self.assertEqual(*self.invoke())

    def test_wrong_type_prefix_or_overlong_oid_never_normalizes(self):
        for commit in ({'__typename': 'Tag', 'oid': SHA}, {'__typename': 'Commit', 'oid': 'b'*40},
                       {'__typename': 'Commit', 'oid': SHA+'a'}, {'__typename': 'Commit', 'oid': None}):
            self.payload['data']['repository']['c0'] = commit
            self.assertEqual(*self.invoke())

    def test_full_id_requires_no_api_resolution(self):
        before, after = self.invoke('Reviewed commit: ' + SHA)
        self.assertEqual(before, after)
        self.assertFalse((self.path/'calls').exists())

    def test_non_provider_comment_grants_no_normalization(self):
        self.assertEqual(*self.invoke(bot='attacker'))
        self.assertFalse((self.path/'calls').exists())

    def test_malformed_short_overlong_and_conflicting_fields_stay_non_clearance(self):
        for body in ('Reviewed commit: aaaaaa', 'Reviewed commit: '+SHA[:10]+'.suffix',
                     'Reviewed commit: '+SHA+'a', 'Reviewed commit: '+SHA[:10]+'\nReviewed commit: '+'b'*40,
                     'Reviewed commit: '+SHA[:10]+'\nReviewed commit: ???'):
            self.assertEqual(*self.invoke(body))

    def test_matching_full_and_uniquely_resolved_short_fields_agree(self):
        before, after = self.invoke('Reviewed commit: '+SHA[:10]+'\nReviewed commit: '+SHA)
        self.assertNotEqual(before, after)
        self.assertEqual(after.count(SHA), 2)

    def test_duplicate_prefix_reuses_one_bounded_api_read(self):
        self.invoke('Reviewed commit: '+SHA[:10]+'\nReviewed commit: '+SHA[:10])
        self.assertEqual(len((self.path/'calls').read_text().splitlines()), 1)

    def test_distinct_historical_prefixes_use_one_api_read(self):
        other = 'b' * 40
        self.payload['data']['repository'].update(b1=None, t1=None,
            c1={'__typename': 'Commit', 'oid': other})
        before, after = self.invoke('Reviewed commit: '+SHA[:10]+'\nReviewed commit: '+other[:10])
        self.assertEqual(before, after)  # Conflicting anchors still cannot clear.
        calls = (self.path/'calls').read_text().splitlines()
        self.assertEqual(len(calls), 1)
        self.assertIn('c1:object', calls[0])

    def test_prefix_error_does_not_poison_independent_resolution(self):
        self.payload['errors'] = [{'message': 'ambiguous', 'path': ['repository', 'c1']}]
        self.payload['data']['repository'].update(b1=None, t1=None, c1=None)
        self.status = 1  # gh returns nonzero for partial GraphQL errors.
        before, after = self.invoke(['Reviewed commit: '+SHA[:10], 'Reviewed commit: '+SHA[:11]])
        self.assertNotEqual(before, after)
        self.assertIn(SHA, after)
        self.assertEqual(self.output[1]['body'], 'Reviewed commit: '+SHA[:11])
        self.payload['errors'][0]['path'] = ['repository', 'c0']
        self.assertEqual(*self.invoke())

    def test_lookup_batch_has_a_fixed_prefix_limit(self):
        body = '\n'.join('Reviewed commit: '+format(n, '010x') for n in range(60))
        self.assertEqual(*self.invoke(body))
        query = json.loads((self.path/'calls').read_text().splitlines()[0])[3]
        self.assertEqual(query.count(':object('), 50)


if __name__ == '__main__':
    unittest.main()
