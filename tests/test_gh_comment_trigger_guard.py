#!/usr/bin/env python3
"""Literal command detection and immutable-payload controls for #2158."""
import importlib.util
import io
import json
import os
import shutil
import signal
import subprocess
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("guard", ROOT / "scripts/workflow/gh-comment-trigger-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


# The fake gh records every write in WRITE_LOG, appends each PR comment to a
# per-PR timeline, prints the comment URL gh would print, and answers the
# wrapper's readback of one comment by id (#1362).
FAKE_GH = r"""#!/usr/bin/env python3
import json, os, re, sys, time
from pathlib import Path
args = sys.argv[1:]
timeline = Path(os.environ["TIMELINE_DIR"])
def hold(name):
    # Optional gates let a test hold the claimed POST or its readback.
    gate = os.environ.get(f"{name}_GATE")
    if gate:
        Path(gate + ".reached").touch()
        while not Path(gate).exists():
            time.sleep(0.05)
read = re.fullmatch(r"repos/[^/]+/[^/]+/issues/comments/([0-9]+)", args[1]) if args[:1] == ["api"] and len(args) == 2 else None
if read:
    hold("READBACK")
    # READBACK_FAILURES=N fails the first N readbacks, as a transient 5xx or a
    # read-after-write delay would (#2769).
    failures = int(os.environ.get("READBACK_FAILURES", "0"))
    if failures:
        counter = timeline / "readback-failures.count"
        seen = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(seen + 1))
        if seen < failures:
            sys.exit(1)
    # READBACK_EMPTY=N answers the first N readbacks with success and no body.
    empty = int(os.environ.get("READBACK_EMPTY", "0"))
    if empty:
        counter = timeline / "readback-empty.count"
        seen = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(seen + 1))
        if seen < empty:
            sys.exit(0)
    for path in timeline.glob("*.jsonl"):
        for line in path.read_text().splitlines():
            comment = json.loads(line)
            if str(comment["id"]) == read.group(1):
                print(json.dumps(comment))
                sys.exit(0)
    sys.exit(1)
pull = re.fullmatch(r"repos/o/r/pulls/([0-9]+)", args[1]) if args[:1] == ["api"] and len(args) == 2 else None
if pull:  # the REST transport's pre-write PR read
    print(json.dumps({"number": int(pull.group(1)), "html_url": f"https://github.com/o/r/pull/{pull.group(1)}", "head": {"sha": "a" * 40}}))
    sys.exit(0)
with open(os.environ["WRITE_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
def post(pr, body):
    hold("POST")
    existing = sum(len(p.read_text().splitlines()) for p in timeline.glob("*.jsonl"))
    comment = {"id": 1000 + existing + 1, "user": {"login": os.environ.get("FAKE_POSTED_AS", "nathanjohnpayne")},
               "body": body, "issue_url": f"https://api.github.com/repos/o/r/issues/{pr}",
               "html_url": f"https://github.com/o/r/pull/{pr}#issuecomment-{1000 + existing + 1}"}
    with open(timeline / f"{pr}.jsonl", "a") as out:
        out.write(json.dumps(comment) + "\n")
    return comment
if args[:2] == ["pr", "comment"] and "--body" in args:
    comment = post(args[2], args[args.index("--body") + 1])
    if os.environ.get("FAKE_OMIT_URL") != "1":
        print(comment["html_url"])
rest = re.fullmatch(r"repos/o/r/issues/([0-9]+)/comments", args[3]) if args[:3] == ["api", "--method", "POST"] and len(args) == 6 else None
if rest:
    print(json.dumps(post(rest.group(1), json.loads(Path(args[5]).read_text())["body"])))
"""

# The authorization stand-in for the claim tests: it records its arrival at
# the recount, waits until RELEASE exists, then authorizes only while the PR's
# timeline has no trigger, the way the real recount refuses an existing one.
HELD_RECOUNT = r"""#!/bin/sh
: > "$ARRIVED/$$.$3"
while [ ! -e "$RELEASE" ]; do sleep 0.05; done
if [ -s "$TIMELINE_DIR/$3.jsonl" ]; then
  echo '[codex-review-request] ERROR: trigger not authorized: existing-trigger' >&2
  printf '{"authorized":false,"reason":"existing-trigger"}\n'
  exit 3
fi
printf '{"authorized":true,"repo":"o/r","pr_number":%s,"head_sha":"%s","author_identity":"nathanjohnpayne"}\n' "$3" "$MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD"
"""


class TriggerGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir()

    def check(self, args, role="reviewer", state=True):
        current = None
        if state:
            current = Path(tempfile.mkdtemp(dir=self.root))
        return guard.inspect(["gh", *args], role, current)

    def test_literal_prose_fences_case_and_whitespace(self):
        for body in ("Please avoid `@codex review` in prose.", "```\n@CoDeX ReViEw\n```", "prefix @codex\nreview suffix"):
            for noun, verb in (("pr", "comment"), ("pr", "review"), ("issue", "comment")):
                with self.subTest(body=body, channel=(noun, verb)), self.assertRaises(guard.Refused):
                    self.check([noun, verb, "123", "--body", body])

    def test_owner_tiebreak_marker_is_refused_for_every_role_and_channel(self):
        head = "a" * 40
        marker = f"TIEBREAK_REBUTTAL_ACCEPTED=https://github.com/o/r/pull/7@{head}#4320643605"
        for body in (marker, f"Owner says:\n```\n{marker.lower()}\n```", f"x {marker} y"):
            for role in ("reviewer", "author", "hook"):
                for noun, verb in (("pr", "comment"), ("pr", "review"), ("issue", "comment")):
                    with self.subTest(body=body, role=role, channel=(noun, verb)), self.assertRaises(guard.Refused):
                        self.check([noun, verb, "7", "--body", body], role=role)

    def test_owner_runaway_marker_is_refused_for_every_role_and_channel(self):
        head = "b" * 40
        marker = f"TIEBREAK_RUNAWAY_ACCEPTED=https://github.com/o/r/pull/7@{head}"
        for body in (marker, f"Owner says:\n```\n{marker.lower()}\n```", f"x {marker} y"):
            for role in ("reviewer", "author", "hook"):
                for noun, verb in (("pr", "comment"), ("pr", "review"), ("issue", "comment")):
                    with self.subTest(body=body, role=role, channel=(noun, verb)), self.assertRaises(guard.Refused):
                        self.check([noun, verb, "7", "--body", body], role=role)

    def test_failover_marker_needs_the_requester_write_context(self):
        marker = "<!-- mergepath-codex-failover:v1 head=" + "c" * 40 + " trigger_comment_id=4321 -->"
        with patch.dict(os.environ, {"MERGEPATH_CODEX_FAILOVER_MARKER_WRITE": "1"}):
            args, meta = self.check(["pr", "comment", "7", "--body", marker], role="author")
            self.assertTrue(meta["guarded"])
            for role, argv in (("reviewer", ["pr", "comment", "7", "--body", marker]),
                               ("author", ["issue", "comment", "7", "--body", marker]),
                               ("author", ["pr", "review", "7", "--comment", "--body", marker]),
                               ("author", ["pr", "comment", "7", "--body", "note\n" + marker]),
                               ("author", ["pr", "comment", "7", "--body", marker.replace("v1", "v2")])):
                with self.subTest(role=role, argv=argv), self.assertRaises(guard.Refused):
                    self.check(argv, role=role)
        with patch.dict(os.environ, {"MERGEPATH_CODEX_FAILOVER_MARKER_WRITE": ""}), self.assertRaises(guard.Refused):
            self.check(["pr", "comment", "7", "--body", marker], role="author")
        for body in ("The marker is <!-- mergepath-codex-failover:v1 head=<full-sha> trigger_comment_id=<id> -->.",
                     "mergepath-codex-failover:v1 head=abc"):
            with self.subTest(body=body):
                self.assertTrue(self.check(["pr", "comment", "7", "--body", body])[1]["guarded"])

    def test_owner_tiebreak_placeholders_and_prose_remain_allowed(self):
        for body in ("Post TIEBREAK_REBUTTAL_ACCEPTED=<PR-URL>@<full-head-sha>#<finding-id> to settle it.",
                     "The TIEBREAK_REBUTTAL_ACCEPTED marker names a finding.",
                     "TIEBREAK_REBUTTAL_ACCEPTED=https://github.com/o/r/pull/7@abc#12",
                     "Post TIEBREAK_RUNAWAY_ACCEPTED=<PR-URL>@<full-head-sha> to release it.",
                     "TIEBREAK_RUNAWAY_ACCEPTED=https://github.com/o/r/pull/7@abc"):
            with self.subTest(body=body):
                args, meta = self.check(["pr", "comment", "7", "--body", body])
                self.assertTrue(meta["guarded"])

    def test_files_and_json_sources(self):
        body = self.root / "comment.md"
        body.write_text("Explain `@codex review` safely.")
        payload = self.root / "payload.json"
        payload.write_text(json.dumps({"body": body.read_text()}))
        for args in (["pr", "comment", "123", "--body-file", str(body)],
                     ["api", "repos/o/r/issues/123/comments", "-F", "body=@" + str(body)],
                     ["api", "-X", "POST", "repos/o/r/pulls/123/reviews", "--input", str(payload)],
                     ["api", "repos/o/r/pulls/123/reviews", "-f", "body=" + body.read_text()],
                     ["api", "-X", "PUT", "repos/o/r/pulls/123/reviews/456", "-f", "body=" + body.read_text()],
                     ["api", "repos/o/r/pulls/123/comments/456/replies", "-f", "body=" + body.read_text()],
                     ["api", "repos/o/r/pulls/123/reviews/456/events", "-f", "body=" + body.read_text(), "-f", "event=COMMENT"],
                     ["api", "repos/o/r/pulls/123/reviews/456/events", "--input", str(payload)]):
            with self.subTest(args=args), self.assertRaises(guard.Refused):
                self.check(args)

    def test_graphql_comment_mutation_payload_forms(self):
        query = 'mutation Post($text: String!) { posted: addComment(input: {subjectId: "P", body: $text}) { clientMutationId } }'
        query_file = self.root / "comment.graphql"
        query_file.write_text(query)
        text_file = self.root / "text.txt"
        text_file.write_text("Explain @codex review safely.")
        payload = self.root / "graphql.json"
        payload.write_text(json.dumps({"query": query, "variables": {"text": text_file.read_text()}}))
        forms = [
            ["api", "graphql", "-f", "query=" + query, "-f", "text=" + text_file.read_text()],
            ["api", "/graphql", "-F", "query=@" + str(query_file), "-F", "text=@" + str(text_file)],
            ["api", "https://api.github.com/graphql", "--input", str(payload)],
            ["api", "graphql", "-f", r'query=mutation { addComment(input: {subjectId: "P", body: "\u0040codex review"}) { clientMutationId } }'],
            ["api", "graphql?" + urlencode({"query": query, "variables": json.dumps({"text": text_file.read_text()})}), "-X", "POST"],
        ]
        for role in ("author", "reviewer", "hook"):
            for args in forms:
                with self.subTest(role=role, args=args), self.assertRaises(guard.Refused):
                    self.check(args, role=role)

    def test_graphql_reads_and_noncomment_mutations_remain_supported(self):
        queries = [
            'query Read($text: String!) { search(query: $text, type: ISSUE) { issueCount } }',
            '# mutation { addComment(input: {}) }\nquery { viewer { login } }',
            'query { search(query: "mutation { addComment(input: {}) } @codex review", type: ISSUE) { issueCount } }',
            'query addComment($text: String!) { search(query: $text, type: ISSUE) { issueCount } }',
            'mutation Resolve($id: ID!) { resolveReviewThread(input: {threadId: $id}) { clientMutationId } }',
            'mutation addComment($id: ID!) { resolveReviewThread(input: {threadId: $id}) { clientMutationId } }',
            'mutation Delete($id: ID!) { deleteIssueComment(input: {id: $id}) { clientMutationId } }',
        ]
        for query in queries:
            with self.subTest(query=query):
                _, meta = self.check(["api", "graphql", "-f", "query=" + query, "-f", "text=@codex review"])
                self.assertFalse(meta["trigger"])

    def test_graphql_known_comment_calls_and_canonical_context(self):
        names = (
            "addComment", "addDiscussionComment", "addPullRequestReview",
            "addPullRequestReviewComment", "addPullRequestReviewThread",
            "addPullRequestReviewThreadReply", "submitPullRequestReview",
            "updateDiscussionComment", "updateIssueComment",
            "updatePullRequestReview", "updatePullRequestReviewComment",
        )
        for name in names:
            query = 'mutation Post($body: String!) { alias: ' + name + '(input: {body: $body}) { clientMutationId } }'
            with self.subTest(name=name), patch.dict(os.environ, {
                "MERGEPATH_CODEX_TRIGGER_WRITE": "1",
                "MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD": "a" * 40,
            }), self.assertRaises(guard.Refused):
                self.check(["api", "graphql", "-f", "query=" + query, "-f", "body=@codex review"], role="author")

    def test_graphql_stdin_and_hook_deferral(self):
        raw = json.dumps({"query": 'mutation { addComment(input: {body: "@codex review"}) { clientMutationId } }'}).encode()
        stream = io.TextIOWrapper(io.BytesIO(raw))
        with patch.object(guard.sys, "stdin", stream), self.assertRaises(guard.Refused):
            self.check(["api", "graphql", "--input", "-"])
        _, meta = self.check(["api", "graphql", "--input", str(self.root / "missing.json")], role="hook", state=False)
        self.assertTrue(meta["deferred"])

    def test_graphql_hook_requires_wrapper_for_readable_file_inputs(self):
        query = self.root / "read.graphql"
        query.write_text("query { viewer { login } }")
        payload = self.root / "read.json"
        payload.write_text(json.dumps({"query": query.read_text()}))
        for fields in (["--input", str(payload)], ["-F", "query=@" + str(query)]):
            with self.subTest(fields=fields):
                args = ["api", "graphql", *fields]
                normalized, meta = self.check(args, role="hook", state=False)
                self.assertEqual(["gh", *args], normalized)
                self.assertTrue(meta["guarded"], "file inputs must reach the runtime snapshot")
                self.assertTrue(meta["deferred"])
        _, meta = self.check(["api", "graphql", "-f", "query=" + query.read_text()], role="hook", state=False)
        self.assertFalse(meta["guarded"], "inline reads need no file snapshot")

    def test_graphql_runtime_read_snapshot_survives_original_file_replacement(self):
        safe = "query { viewer { login } }"
        mutation = 'mutation { addComment(input:{subjectId:"P",body:"@codex review"}) { clientMutationId } }'
        for json_input in (False, True):
            original = self.root / ("snapshot.json" if json_input else "snapshot.graphql")
            original.write_text(json.dumps({"query": safe}) if json_input else safe)
            fields = ["--input", str(original)] if json_input else ["-F", "query=@" + str(original)]
            normalized, _ = self.check(["api", "graphql", *fields])
            snapshot = Path(normalized[-1] if json_input else normalized[-1].split("=@", 1)[1])
            self.assertNotEqual(original, snapshot)
            original.write_text(json.dumps({"query": mutation}) if json_input else mutation)
            contents = snapshot.read_text()
            self.assertEqual(safe, json.loads(contents)["query"] if json_input else contents)
            for role in ("author", "reviewer"):
                with self.subTest(json_input=json_input, role=role), self.assertRaises(guard.Refused):
                    self.check(["api", "graphql", *fields], role=role)

    def test_readable_cli_and_rest_files_require_runtime_snapshot(self):
        body = self.root / "safe.md"
        body.write_text("Safe comment")
        payload = self.root / "safe.json"
        payload.write_text(json.dumps({"body": body.read_text()}))
        for args in (["pr", "comment", "123", "--body-file", str(body)],
                     ["api", "repos/o/r/issues/123/comments", "--input", str(payload)],
                     ["api", "repos/o/r/issues/123/comments", "-F", "body=@" + str(body)]):
            with self.subTest(args=args):
                _, meta = self.check(args, role="hook", state=False)
                self.assertTrue(meta["guarded"])
                self.assertTrue(meta["deferred"])
                self.assertFalse(meta["trigger"])

    def test_graphql_keyword_fragment_spread_cannot_hide_comment_call(self):
        for fragment in ("query", "mutation", "subscription"):
            query = ('mutation { ...' + fragment + ' addComment(input:{subjectId:"P", '
                     'body:"@codex review"}) { clientMutationId } } fragment '
                     + fragment + ' on Mutation { __typename }')
            for role in ("author", "reviewer"):
                with self.subTest(fragment=fragment, role=role), self.assertRaises(guard.Refused):
                    self.check(["api", "graphql", "-f", "query=" + query], role=role)

    def test_graphql_valueless_empty_array_fields_preserve_read_calls(self):
        query = 'query($ids:[ID!]!) { nodes(ids:$ids) { id } }'
        for field in (["-F", "ids[]"], ["-Fids[]"], ["--field=ids[]"]):
            args = ["api", "graphql", "-f", "query=" + query, *field]
            normalized, meta = self.check(args)
            self.assertEqual(["gh", *args], normalized)
            self.assertFalse(meta["guarded"])

    def test_graphql_empty_array_does_not_skip_other_mutation_fields(self):
        query = 'mutation { addComment(input:{subjectId:"P", body:"@codex review"}) { clientMutationId } }'
        with self.assertRaises(guard.Refused):
            self.check(["api", "graphql", "-F", "ids[]", "-f", "query=" + query])
        with self.assertRaises(guard.Refused):
            self.check(["api", "graphql", "-F", "ids", "-f", 'query=query { viewer { login } }'])

    def test_graphql_bom_between_comment_call_tokens_is_ignored(self):
        query = 'mutation { addComment\ufeff(input: {subjectId:"P", body:"@codex review"}) { clientMutationId } }'
        for role in ("author", "reviewer"):
            with self.subTest(role=role), self.assertRaises(guard.Refused):
                self.check(["api", "graphql", "-f", "query=" + query], role=role)

    def test_graphql_block_string_backslash_cannot_hide_comment_call(self):
        query = ('mutation M($a: String = """\\\\""" """) { addComment(input: {subjectId:"P", '
                 'clientMutationId:$a, body:"@codex review"}) { clientMutationId } } # """')
        for role in ("author", "reviewer"):
            with self.subTest(role=role), self.assertRaises(guard.Refused):
                self.check(["api", "graphql", "-f", "query=" + query], role=role)

    def test_graphql_escaped_block_string_and_bom_read_data_remain_supported(self):
        query = 'query { node(id:"""literal \\""" addComment( @codex review \ufeff """) { id } }'
        args = ["api", "graphql", "-f", "query=" + query]
        normalized, meta = self.check(args)
        self.assertEqual(["gh", *args], normalized)
        self.assertFalse(meta["guarded"])

    def test_graphql_unsupported_literal_is_refused_without_unbounded_backtracking(self):
        query = 'mutation { addComment(input: {body: """' + "\\" * 1000
        with self.assertRaises(guard.Refused):
            self.check(["api", "graphql", "-f", "query=" + query])

    def test_graphql_read_input_is_frozen_before_execution(self):
        payload = self.root / "graphql-read.json"
        raw = b'{"query":"query { viewer { login } }"}\n'
        payload.write_bytes(raw)
        args, meta = self.check(["api", "graphql", "--input", str(payload)])
        payload.write_text(json.dumps({"query": 'mutation { addComment(input: {body: "@codex review"}) { clientMutationId } }'}))
        self.assertEqual(raw, Path(args[-1]).read_bytes())
        self.assertFalse(meta["trigger"])

    def test_unreadable_payload_file_names_the_path_not_the_encoding(self):
        missing = self.root / "never-written.md"
        directory = self.root / "a-directory"
        directory.mkdir()
        for path, reason in ((missing, "No such file or directory"), (directory, "Is a directory")):
            for args in (["issue", "comment", "518", "--body-file", str(path)],
                         ["pr", "comment", "123", "-F", str(path)]):
                with self.subTest(path=path.name, args=args[:2]):
                    with self.assertRaises(guard.Refused) as caught:
                        self.check(args)
                    message = str(caught.exception)
                    self.assertIn("could not be read", message)
                    self.assertIn(reason, message)
                    self.assertIn(str(path), message)
                    self.assertNotIn("UTF-8", message)

    def test_non_utf8_payload_keeps_the_encoding_message(self):
        body = self.root / "latin1.md"
        body.write_bytes("caf\xe9".encode("latin-1"))
        with self.assertRaises(guard.Refused) as caught:
            self.check(["issue", "comment", "518", "--body-file", str(body)])
        self.assertIn("cannot be read as UTF-8", str(caught.exception))

    def test_snapshot_preserves_unicode_and_trailing_newlines(self):
        body = self.root / "comment.md"
        raw = "A review with café and 🟡.\n\n".encode()
        body.write_bytes(raw)
        args, meta = self.check(["pr", "comment", "123", "-F", str(body)])
        body.write_text("Changed to `@codex review` after validation.")
        self.assertEqual(raw, Path(args[-1]).read_bytes())
        self.assertFalse(meta["trigger"])
        self.assertEqual(0o600, Path(args[-1]).stat().st_mode & 0o777)

    def test_json_snapshot_retains_original_bytes_and_nested_bodies(self):
        payload = self.root / "request.json"
        raw = b'{ "event": "APPROVE", "body": "Safe comment" }\n'
        payload.write_bytes(raw)
        args, _ = self.check(["api", "repos/o/r/pulls/123/reviews", "--input", str(payload)])
        self.assertEqual(raw, Path(args[-1]).read_bytes())
        payload.write_text(json.dumps({"comments": [{"body": "Mention @codex review"}]}))
        with self.assertRaises(guard.Refused):
            self.check(["api", "repos/o/r/pulls/123/reviews", "--input", str(payload)], state=False)

    def test_genuine_command_requires_author_context_and_canonical_bytes(self):
        args = ["pr", "comment", "123", "--repo", "o/r", "--body", " \n@CoDeX  review\n"]
        for role in ("author", "reviewer", "hook"):
            with self.subTest(role=role), patch.dict(os.environ, {}, clear=True), self.assertRaises(guard.Refused):
                self.check(args, role=role, state=False)
        with patch.dict(os.environ, {"MERGEPATH_CODEX_TRIGGER_WRITE": "1", "MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD": "a" * 40}, clear=True):
            normalized, meta = self.check(args, role="author")
        self.assertEqual("@codex review", normalized[-1])
        self.assertTrue(meta["trigger"])
        self.assertEqual(("o/r", 123, "a" * 40), (meta["repo"], meta["pr"], meta["head"]))

    def test_read_only_requests_and_raw_at_file_values(self):
        args, meta = self.check(["api", "-X", "GET", "repos/o/r/issues/123/comments", "-f", "body=@codex review"])
        self.assertFalse(meta["guarded"])
        body = self.root / "body"
        body.write_text("@codex review")
        _, meta = self.check(["api", "repos/o/r/issues/123/comments", "-f", "body=@" + str(body)])
        self.assertFalse(meta["trigger"])

    def test_stdin_is_snapshotted_at_runtime_and_deferred_at_hook(self):
        args = ["pr", "comment", "123", "--body-file", "-"]
        _, meta = self.check(args, role="hook", state=False)
        self.assertTrue(meta["deferred"])
        stream = io.TextIOWrapper(io.BytesIO(b"Safe stdin comment\n"))
        with patch.object(guard.sys, "stdin", stream):
            normalized, _ = self.check(args)
        self.assertEqual(b"Safe stdin comment\n", Path(normalized[-1]).read_bytes())
        _, metadata = self.check(args, role="hook", state=False)
        self.assertTrue(metadata["cli_stdin"])

    def wrapper_fixture(self):
        fixture = self.root / "wrapper"
        (fixture / "scripts/lib").mkdir(parents=True)
        (fixture / "scripts/workflow").mkdir()
        (fixture / "bin").mkdir()
        for name in ("gh-as-author.sh", "gh-as-reviewer.sh"):
            shutil.copy(ROOT / "scripts" / name, fixture / "scripts" / name)
        for name in ("gh-token-resolver.sh", "gh-command-classifier.sh", "pr-body-contract.sh", "reviewers-helpers.sh", "credential-class.sh", "gh-comment-trigger-guard.sh", "gh-rest-transport.sh"):
            shutil.copy(ROOT / "scripts/lib" / name, fixture / "scripts/lib" / name)
        for name in ("gh-comment-trigger-guard.py", "owner-admin-override.py", "merge-writer.py"):
            shutil.copy(ROOT / "scripts/workflow" / name, fixture / "scripts/workflow" / name)
        checker = fixture / "scripts/identity-check.sh"
        checker.write_text("#!/bin/sh\nexit 0\n")
        checker.chmod(0o755)
        gh = fixture / "bin/gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        authorize = fixture / "scripts/codex-review-request.sh"
        authorize.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$AUTH_LOG\"\nexit 7\n")
        authorize.chmod(0o755)
        body = fixture / "body.md"
        body.write_text("The guard missed `@codex review` in prose.")
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN", "OP_PREFLIGHT_AUTHOR_PAT", "OP_PREFLIGHT_REVIEWER_PAT")}
        # This fixture asserts native gh argv. REST transport has its own suite.
        env.update(PATH=str(fixture / "bin") + os.pathsep + env["PATH"], OP_PREFLIGHT_CACHE_DIR=str(fixture / "empty-cache"), OP_PREFLIGHT_AUTHOR_PAT="ghp_fixture_author", OP_PREFLIGHT_REVIEWER_PAT="ghp_fixture_reviewer", WRITE_LOG=str(fixture / "writes"), AUTH_LOG=str(fixture / "auth"), MERGEPATH_AGENT="codex", MERGEPATH_GH_TRANSPORT="gh",
                   TIMELINE_DIR=str(fixture / "timeline"), MERGEPATH_CODEX_REQUEST_CLAIM_DIR=str(fixture / "claims"))
        env.pop("MERGEPATH_CODEX_REQUEST_CLAIM_HELD", None)
        (fixture / "timeline").mkdir()
        return fixture, env

    def test_real_wrappers_refuse_accidental_trigger_before_gh_write(self):
        fixture, env = self.wrapper_fixture()
        body = fixture / "body.md"
        authorize = fixture / "scripts/codex-review-request.sh"
        for role in ("author", "reviewer"):
            result = subprocess.run(["bash", str(fixture / f"scripts/gh-as-{role}.sh"), "--", "gh", "pr", "comment", "123", "--body-file", str(body)], env=env, capture_output=True, timeout=10)
            self.assertNotEqual(0, result.returncode, result.stderr)
            self.assertFalse((fixture / "writes").exists())
            query = 'mutation Post($text: String!) { addComment(input: {subjectId: "P", body: $text}) { clientMutationId } }'
            result = subprocess.run(["bash", str(fixture / f"scripts/gh-as-{role}.sh"), "--", "gh", "api", "graphql", "-f", "query=" + query, "-F", "text=@" + str(body)], env=env, capture_output=True, timeout=10)
            self.assertNotEqual(0, result.returncode)
            self.assertFalse((fixture / "writes").exists(), "GraphQL trigger prose must be refused before the fake GH write")
        env.update(MERGEPATH_CODEX_TRIGGER_WRITE="1", MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD="a" * 40)
        result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"], env=env, capture_output=True, timeout=10)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("--authorize-trigger-write", (fixture / "auth").read_text())
        self.assertFalse((fixture / "writes").exists(), "Spent canonical authorization must prevent a GH write")
        authorize.write_text("#!/bin/sh\nprintf '%s\\n' '{\"authorized\":true,\"repo\":\"o/r\",\"pr_number\":123,\"head_sha\":\"" + "a" * 40 + "\",\"author_identity\":\"nathanjohnpayne\"}'\n")
        result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "  @CoDeX  review\n"], env=env, capture_output=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["pr comment 123 --repo o/r --body @codex review"], (fixture / "writes").read_text().splitlines())

    def claim_fixture(self):
        fixture, env = self.wrapper_fixture()
        requester = fixture / "scripts/codex-review-request.sh"
        requester.write_text(HELD_RECOUNT)
        requester.chmod(0o755)
        (fixture / "arrived").mkdir()
        env.update(MERGEPATH_CODEX_TRIGGER_WRITE="1", MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD="a" * 40,
                   ARRIVED=str(fixture / "arrived"), RELEASE=str(fixture / "release"))
        return fixture, env

    def start_trigger(self, fixture, env, pr="123"):
        command = ["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", pr, "--repo", "o/r", "--body", "@codex review"]
        return subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

    def stop(self, proc):
        # The held recount outlives a killed wrapper; end its whole group.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.communicate(timeout=10)

    def wait_for(self, predicate, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return predicate()

    def writes(self, fixture):
        log = fixture / "writes"
        return log.read_text().splitlines() if log.exists() else []

    def test_claim_lets_exactly_one_of_two_held_wrappers_post(self):
        # #1362: both wrappers are started against the same below-cap PR and
        # the recount holds whoever reaches it. Without the claim both reach
        # the recount, both see an empty timeline and both post.
        # The holder is then also held at its POST and at the readback of its
        # comment id, so a claim released any earlier lets the second recount
        # in while the first is still there.
        fixture, env = self.claim_fixture()
        arrived = fixture / "arrived"
        post_gate, readback_gate = fixture / "post-gate", fixture / "readback-gate"
        env.update(POST_GATE=str(post_gate), READBACK_GATE=str(readback_gate))
        first, second = self.start_trigger(fixture, env), self.start_trigger(fixture, env)
        try:
            self.assertTrue(self.wait_for(lambda: len(list(arrived.iterdir())) >= 1), "neither wrapper reached the recount")
            time.sleep(1.5)
            self.assertEqual(1, len(list(arrived.iterdir())), "the second wrapper reached the recount while the first held the claim")
            self.assertEqual([], self.writes(fixture))
            (fixture / "release").touch()
            for gate, stage in ((post_gate, "POST"), (readback_gate, "comment-id readback")):
                self.assertTrue(self.wait_for(lambda: Path(str(gate) + ".reached").exists()), f"the holder never reached its {stage}")
                time.sleep(1.0)
                self.assertEqual(1, len(list(arrived.iterdir())), f"the second wrapper recounted during the holder's {stage}")
                gate.touch()
            results = [proc.communicate(timeout=30) + (proc.returncode,) for proc in (first, second)]
        finally:
            for proc in (first, second):
                self.stop(proc)
        self.assertEqual(["pr comment 123 --repo o/r --body @codex review"], self.writes(fixture))
        self.assertEqual([0], [rc for _, _, rc in results if rc == 0], results)
        loser = next(err for _, err, rc in results if rc != 0)
        self.assertIn(b"existing-trigger", loser)
        self.assertEqual(2, len(list(arrived.iterdir())), "the second wrapper must recount after the first posted")

    def assert_claim_free_while_orphan_lives(self, fixture, env, arrived, want_arrivals):
        # The killed wrapper's child (held at the recount or the POST) is still
        # alive; a new wrapper must still take the claim and reach the recount.
        nxt = self.start_trigger(fixture, dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS="3"))
        try:
            reached = self.wait_for(lambda: len(list(arrived.iterdir())) >= want_arrivals, seconds=8)
            if not reached:
                nxt.wait(timeout=10)
            self.assertTrue(reached, "a killed wrapper's orphaned child still holds the claim: " + (nxt.stderr.read().decode() if nxt.poll() is not None else "next wrapper still waiting"))
        finally:
            self.stop(nxt)

    def check_claim_held_by_surviving_writer(self, transport, stage="POST"):
        # A's wrapper is killed while its POST (or readback) child is held.
        # That child can still write, so it must keep the claim: B waits, and
        # once A's child finishes B recounts, sees A's request and refuses.
        fixture, env = self.claim_fixture()
        env["MERGEPATH_GH_TRANSPORT"] = transport
        arrived = fixture / "arrived"
        (fixture / "release").touch()
        gate = fixture / "stage-gate"
        held = self.start_trigger(fixture, dict(env, **{f"{stage}_GATE": str(gate)}))
        nxt = None
        try:
            self.assertTrue(self.wait_for(lambda: Path(str(gate) + ".reached").exists()), f"the wrapper never reached its {stage}")
            held.kill()
            held.wait(timeout=10)
            nxt = self.start_trigger(fixture, dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS="20"))
            time.sleep(1.5)
            self.assertEqual(1, len(list(arrived.iterdir())), f"B recounted while A's {stage} child still held the claim")
            gate.touch()
            out, err = nxt.communicate(timeout=30)
            self.assertNotEqual(0, nxt.returncode, err)
            self.assertIn(b"existing-trigger", err)
        finally:
            if nxt is not None:
                self.stop(nxt)
            self.stop(held)
        self.assertEqual(1, len((fixture / "timeline/123.jsonl").read_text().splitlines()), "at most one request may land")

    def test_surviving_post_child_keeps_the_claim(self):
        self.check_claim_held_by_surviving_writer("gh")

    def test_surviving_rest_post_child_keeps_the_claim(self):
        self.check_claim_held_by_surviving_writer("rest")

    def test_surviving_readback_child_keeps_the_claim(self):
        self.check_claim_held_by_surviving_writer("gh", stage="READBACK")

    def test_claim_ends_with_its_wrapper_and_is_per_pr(self):
        fixture, env = self.claim_fixture()
        arrived = fixture / "arrived"
        held = self.start_trigger(fixture, env)
        try:
            self.assertTrue(self.wait_for(lambda: len(list(arrived.iterdir())) == 1))
            # Another PR's request is not serialized behind this one.
            env_other = dict(env, RELEASE=str(fixture / "arrived"))
            other = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "124", "--repo", "o/r", "--body", "@codex review"],
                                   env=env_other, capture_output=True, timeout=20)
            self.assertEqual(0, other.returncode, other.stderr)
            # A wrapper killed while holding the claim leaves no claim behind,
            # even while its recount child lives on, so it cannot suppress a
            # trigger it never sent. Reacquire before that child ends
            # (PR 124's request already arrived at its own recount).
            held.kill()
            held.wait(timeout=10)
            self.assert_claim_free_while_orphan_lives(fixture, env, arrived, 3)
        finally:
            self.stop(held)
        self.assertEqual(["pr comment 124 --repo o/r --body @codex review"], self.writes(fixture))
        (fixture / "release").touch()
        result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                env=dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS="2"), capture_output=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn(b"waiting for another", result.stderr)
        # A refused authorization releases the claim too.
        result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                env=dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS="2"), capture_output=True, timeout=20)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b"existing-trigger", result.stderr)
        self.assertNotIn(b"waiting for another", result.stderr)
        self.assertEqual(2, len(self.writes(fixture)))

    def test_claim_fails_closed_before_the_recount(self):
        fixture, env = self.claim_fixture()
        arrived = fixture / "arrived"
        (fixture / "release").touch()
        blocker = fixture / "not-a-directory"
        blocker.write_text("")
        cases = {
            "unopenable claim directory": dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_DIR=str(blocker)),
            "invalid wait": dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS="soon"),
            # A relative directory names a different lock file per checkout.
            "relative claim directory": dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_DIR="claims"),
            "no absolute root": {k: v for k, v in env.items() if k not in ("MERGEPATH_CODEX_REQUEST_CLAIM_DIR", "HOME", "XDG_STATE_HOME")},
            "nested trigger write": dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_HELD=str(fixture / "claims/o__r#123.lock")),
        }
        for label, case_env in cases.items():
            with self.subTest(label):
                result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                        env=case_env, capture_output=True, timeout=20)
                self.assertNotEqual(0, result.returncode)
                self.assertIn(b"#1362", result.stderr)
                self.assertEqual([], list(arrived.iterdir()), "authorization must not run without a confirmed claim")
                self.assertEqual([], self.writes(fixture))
        # A holder that outlasts the wait refuses, without recounting.
        (fixture / "release").unlink()
        held = self.start_trigger(fixture, env)
        try:
            self.assertTrue(self.wait_for(lambda: len(list(arrived.iterdir())) == 1))
            result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                    env=dict(env, MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS="1"), capture_output=True, timeout=20)
            self.assertNotEqual(0, result.returncode)
            self.assertIn(b"still holds the per-PR claim", result.stderr)
            self.assertEqual(1, len(list(arrived.iterdir())))
        finally:
            self.stop(held)
        self.assertEqual([], self.writes(fixture))

    def test_claim_covers_the_rest_transport(self):
        # The cloud surface posts through the REST transport; the same claim
        # and comment-id readback apply, and a second request is refused.
        fixture, env = self.claim_fixture()
        (fixture / "release").touch()
        env["MERGEPATH_GH_TRANSPORT"] = "rest"
        command = ["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"]
        result = subprocess.run(command, env=env, capture_output=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stderr)
        result = subprocess.run(command, env=env, capture_output=True, timeout=20)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b"existing-trigger", result.stderr)
        writes = self.writes(fixture)
        self.assertEqual(1, len(writes), writes)
        self.assertTrue(writes[0].startswith("api --method POST repos/o/r/issues/123/comments --input "), writes)
        self.assertEqual(1, len((fixture / "timeline/123.jsonl").read_text().splitlines()))

    def test_claim_directory_is_absolute_and_shared(self):
        # A relative XDG_STATE_HOME is ignored, so two checkouts (different
        # working directories) still share one lock under $HOME.
        fixture, env = self.claim_fixture()
        (fixture / "release").touch()
        home = fixture / "home"
        home.mkdir()
        env = {k: v for k, v in env.items() if k != "MERGEPATH_CODEX_REQUEST_CLAIM_DIR"}
        env.update(HOME=str(home), XDG_STATE_HOME="state")
        results = [subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                  env=env, cwd=cwd, capture_output=True, timeout=20)
                   for cwd in (fixture, fixture / "scripts")]
        self.assertEqual([0], [r.returncode for r in results if r.returncode == 0], [r.stderr for r in results])
        self.assertTrue((home / ".local/state/mergepath/codex-request-claims/o__r#123.lock").exists())
        self.assertFalse((fixture / "state").exists() or (fixture / "scripts/state").exists())
        self.assertEqual(1, len(self.writes(fixture)), "the second checkout must recount against the same lock and refuse")

    def test_claimed_write_requires_its_confirmed_comment_id(self):
        fixture, env = self.claim_fixture()
        (fixture / "release").touch()
        for label, extra in (("no comment id", {"FAKE_OMIT_URL": "1"}), ("foreign author", {"FAKE_POSTED_AS": "nathanpayne-codex"})):
            with self.subTest(label):
                for path in (fixture / "timeline").iterdir():
                    path.unlink()
                result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                        env=dict(env, **extra), capture_output=True, timeout=20)
                self.assertEqual(5, result.returncode, result.stderr)
                self.assertIn(b"without a confirmed comment id", result.stderr)

    def test_claimed_write_retries_a_failed_readback(self):
        # #2769: the POST landed but the first readbacks fail. A bounded retry
        # confirms it; only readbacks that keep failing past the bound refuse.
        fixture, env = self.claim_fixture()
        (fixture / "release").touch()
        env.update(MERGEPATH_CODEX_REQUEST_READBACK_DELAY_SECONDS="0", MERGEPATH_CODEX_REQUEST_READBACK_ATTEMPTS="3")
        command = ["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"]
        for mode, failures, expected in (("FAILURES", 2, 0), ("FAILURES", 3, 5), ("EMPTY", 2, 0)):
            with self.subTest(mode=mode, failures=failures):
                for path in (fixture / "timeline").iterdir():
                    path.unlink()
                result = subprocess.run(command, env=dict(env, **{"READBACK_" + mode: str(failures)}), capture_output=True, timeout=20)
                self.assertEqual(expected, result.returncode, result.stderr)
                self.assertEqual(str(min(failures + 1, 3)), (fixture / f"timeline/readback-{mode.lower()}.count").read_text())
                self.assertEqual(1, len((fixture / "timeline/123.jsonl").read_text().splitlines()))
        # A zero-padded delay is not read as octal arithmetic (CodeRabbit on #2846).
        for path in (fixture / "timeline").iterdir():
            path.unlink()
        result = subprocess.run(command, env=dict(env, READBACK_FAILURES="1", MERGEPATH_CODEX_REQUEST_READBACK_DELAY_SECONDS="08",
                                                  MERGEPATH_CODEX_REQUEST_READBACK_ATTEMPTS="2"), capture_output=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn(b"value too great for base", result.stderr)

    def test_out_of_band_request_is_counted_never_blocked(self):
        # The claim governs guarded writes only. A request typed in the GitHub
        # web UI takes no part in it and cannot be prevented; it lands on the
        # timeline, which is the budget store, so the next guarded recount
        # counts it. Here it stands as an existing trigger on the head.
        fixture, env = self.claim_fixture()
        (fixture / "release").touch()
        (fixture / "timeline/123.jsonl").write_text(json.dumps({"id": 1, "user": {"login": "nathanjohnpayne"}, "body": "@codex review", "issue_url": "https://api.github.com/repos/o/r/issues/123"}) + "\n")
        result = subprocess.run(["bash", str(fixture / "scripts/gh-as-author.sh"), "--", "gh", "pr", "comment", "123", "--repo", "o/r", "--body", "@codex review"],
                                env=env, capture_output=True, timeout=20)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], self.writes(fixture))

    def test_real_wrappers_execute_frozen_read_inputs_and_clean_snapshots(self):
        fixture, env = self.wrapper_fixture()
        runtime = fixture / "runtime"
        runtime.mkdir()
        env["TMPDIR"] = str(runtime)
        checker = fixture / "scripts/identity-check.sh"
        checker.write_text('#!/bin/sh\ncp "$REPLACEMENT" "$ORIGINAL"\n')
        gh = fixture / "bin/gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
name = args[args.index("--input") + 1] if "--input" in args else next(a[7:] for a in args if a.startswith("query=@"))
Path(os.environ["WRITE_LOG"]).write_text(json.dumps({"input": name, "body": Path(name).read_text()}))
''')
        safe = "query { viewer { login } }"
        mutation = 'mutation { addComment(input:{subjectId:"P",body:"@codex review"}) { clientMutationId } }'
        original = fixture / "original"
        replacement = fixture / "replacement"
        for role in ("author", "reviewer"):
            for json_input in (False, True):
                with self.subTest(role=role, json_input=json_input):
                    (fixture / "writes").unlink(missing_ok=True)
                    original.write_text(json.dumps({"query": safe}) if json_input else safe)
                    replacement.write_text(json.dumps({"query": mutation}) if json_input else mutation)
                    env.update(ORIGINAL=str(original), REPLACEMENT=str(replacement))
                    fields = ["--input", str(original)] if json_input else ["-F", "query=@" + str(original)]
                    result = subprocess.run(["bash", str(fixture / f"scripts/gh-as-{role}.sh"), "--", "gh", "api", "graphql", *fields], env=env, capture_output=True, timeout=10)
                    self.assertFalse(list(runtime.glob("gh-comment-guard.*")), "wrapper exit must clean snapshots on success or refusal")
                    if role == "author":
                        # Author API grammar separately forbids opaque GraphQL.
                        self.assertEqual(2, result.returncode, result.stderr)
                        self.assertIn(b"require one literal query", result.stderr)
                        self.assertFalse((fixture / "writes").exists())
                        continue
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual(replacement.read_text(), original.read_text())
                    written = json.loads((fixture / "writes").read_text())
                    self.assertNotEqual(str(original), written["input"])
                    self.assertEqual(safe, json.loads(written["body"])["query"] if json_input else written["body"])
                    self.assertFalse(Path(written["input"]).parent.exists(), "wrapper exit must remove the snapshot directory")

    def test_attached_short_options_preserve_supported_spellings(self):
        body = self.root / "attached.md"
        body.write_text("Safe attached body\n")
        for args in (["pr", "comment", "123", "-Ro/r", "-bSafe body"],
                     ["pr", "comment", "123", "-R=o/r", "-F=" + str(body)],
                     ["api", "-XPOST", "repos/o/r/pulls/123/reviews/456/events", "-fbody=Safe body"]):
            with self.subTest(args=args):
                _, meta = self.check(args)
                self.assertTrue(meta["guarded"])
                self.assertFalse(meta["trigger"])

    def test_pre_command_options_and_closing_comments(self):
        body = "Avoid @codex review in prose"
        payload = self.root / "prefix.json"
        payload.write_text(json.dumps({"body": body}))
        blocked = (["-X", "POST", "api", "repos/o/r/issues/123/comments", "-f", "body=" + body],
                   ["--method", "POST", "--input", str(payload), "api", "repos/o/r/issues/123/comments"],
                   ["-f", "body=" + body, "api", "repos/o/r/issues/123/comments"],
                   ["-b", body, "pr", "comment", "123"],
                   ["pr", "-b", body, "comment", "123"],
                   ["pr", "close", "123", "--comment", body],
                   ["--comment", body, "pr", "close", "123"],
                   ["issue", "close", "123", "-c", body],
                   ["pr", "--comment", "--body", body, "review", "123"],
                   ["--reason", "completed", "issue", "close", "123", "--comment", body],
                   ["-r", "completed", "issue", "close", "123", "--comment", body],
                   ["--duplicate-of", "456", "issue", "close", "123", "--comment", body],
                   ["--comment", "--body", body, "pr", "review", "123"])
        for args in blocked:
            with self.subTest(args=args), self.assertRaises(guard.Refused):
                self.check(args)
        original = ["gh", "-X", "GET", "api", "repos/o/r/issues/123/comments", "-f", "body=" + body]
        normalized, meta = guard.inspect(original, "author", self.state)
        self.assertEqual(original, normalized)
        self.assertFalse(meta["guarded"])
        for args in (["pr", "close", "123", "--comment", "Done"],
                     ["-b", "Safe body", "pr", "comment", "123"]):
            _, meta = self.check(args)
            self.assertTrue(meta["guarded"])
            self.assertFalse(meta["trigger"])

    def test_comment_free_closes_preserve_hook_scope(self):
        for role in ("hook", "author", "reviewer"):
            for args in (["pr", "close", "123"], ["pr", "close", "123", "--delete-branch"],
                         ["issue", "close", "123"], ["issue", "close", "123", "--reason", "completed"],
                         ["-r", "completed", "issue", "close", "123"],
                         ["issue", "-rcompleted", "close", "123"],
                         ["pr", "close", "123", "-dd"], ["pr", "close", "123", "--comment", ""]):
                with self.subTest(role=role, args=args):
                    normalized, meta = self.check(args, role=role)
                    self.assertEqual(["gh", *args], normalized)
                    self.assertFalse(meta["guarded"])
                    self.assertFalse(meta["trigger"])
        with self.assertRaises(guard.Refused):
            self.check(["-r", "completed", "pr", "review", "123", "--body", "Avoid @codex review"])

    def test_clustered_short_flags_fail_closed(self):
        body = "Avoid @codex review in prose"
        for args in (["api", "repos/o/r/issues/123/comments", "-iFbody=" + body],
                     ["-iFbody=" + body, "api", "repos/o/r/issues/123/comments"],
                     ["api", "repos/o/r/issues/123/comments", "-iXPOST", "-f", "body=" + body],
                     ["pr", "review", "123", "-ab" + body],
                     ["pr", "comment", "123", "-ebSafe", "-b", "Safe"]):
            with self.subTest(args=args), self.assertRaises(guard.Refused):
                self.check(args)
        for args in (["api", "repos/o/r/issues/123/comments", "-i", "-Fbody=Safe"],
                     ["pr", "review", "123", "-a", "-bSafe"],
                     ["pr", "close", "123", "-cSafe"],
                     ["issue", "close", "123", "-rcompleted", "-cSafe"]):
            _, meta = self.check(args)
            self.assertTrue(meta["guarded"])
            self.assertFalse(meta["trigger"])

    def test_authorization_metadata_errors_cannot_dispatch(self):
        fixture = self.root / "authorization"
        (fixture / "scripts").mkdir(parents=True)
        call = fixture / "called"
        requester = fixture / "scripts/codex-review-request.sh"
        requester.write_text("#!/bin/sh\ntouch "+str(call)+"\nexit 0\n")
        requester.chmod(0o755)
        helper = ROOT / "scripts/lib/gh-comment-trigger-guard.sh"
        command = 'source "$1"; ROOT="$2"; GH_COMMENT_GUARD_STATE="$3"; gh_comment_guard_authorize'
        metadata = self.state / "metadata.json"
        for body in (None, "{", '{"trigger":"false"}', '{"trigger":null}'):
            if body is None:
                metadata.unlink(missing_ok=True)
            else:
                metadata.write_text(body)
            result = subprocess.run(["bash", "-c", command, "test", str(helper), str(fixture), str(self.state)], capture_output=True)
            self.assertNotEqual(0, result.returncode, body)
            self.assertFalse(call.exists())
        metadata.write_text('{"trigger":false}')
        result = subprocess.run(["bash", "-c", command, "test", str(helper), str(fixture), str(self.state)], capture_output=True)
        self.assertEqual(0, result.returncode)
        fakebin = fixture / "bin"
        fakebin.mkdir()
        (fakebin / "jq").write_text("#!/bin/sh\nexit 127\n")
        (fakebin / "jq").chmod(0o755)
        env = dict(os.environ, PATH=str(fakebin)+os.pathsep+os.environ["PATH"])
        metadata.write_text('{"trigger":true}')
        result = subprocess.run(["bash", "-c", command, "test", str(helper), str(fixture), str(self.state)], env=env, capture_output=True)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(call.exists())

    def test_unreadable_payload_and_interactive_edits_refuse(self):
        for args in (["pr", "comment", "123", "-F", str(self.root / "missing")],
                     ["pr", "comment", "123", "--editor"],
                     ["pr", "review", "123", "--comment"],
                     ["pr", "comment", "123", "--attach", "image.png"]):
            with self.subTest(args=args), self.assertRaises(guard.Refused):
                self.check(args)


if __name__ == "__main__":
    unittest.main()
