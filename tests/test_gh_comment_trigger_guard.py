#!/usr/bin/env python3
"""Literal command detection and immutable-payload controls for #2158."""
import importlib.util
import io
import json
import os
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("guard", ROOT / "scripts/workflow/gh-comment-trigger-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


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

    def test_real_wrappers_refuse_accidental_trigger_before_gh_write(self):
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
        gh.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WRITE_LOG\"\n")
        gh.chmod(0o755)
        authorize = fixture / "scripts/codex-review-request.sh"
        authorize.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$AUTH_LOG\"\nexit 7\n")
        authorize.chmod(0o755)
        body = fixture / "body.md"
        body.write_text("The guard missed `@codex review` in prose.")
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN", "OP_PREFLIGHT_AUTHOR_PAT", "OP_PREFLIGHT_REVIEWER_PAT")}
        env.update(PATH=str(fixture / "bin") + os.pathsep + env["PATH"], OP_PREFLIGHT_CACHE_DIR=str(fixture / "empty-cache"), OP_PREFLIGHT_AUTHOR_PAT="ghp_fixture_author", OP_PREFLIGHT_REVIEWER_PAT="ghp_fixture_reviewer", WRITE_LOG=str(fixture / "writes"), AUTH_LOG=str(fixture / "auth"), MERGEPATH_AGENT="codex")
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
