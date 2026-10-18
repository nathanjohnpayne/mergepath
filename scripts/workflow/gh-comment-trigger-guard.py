#!/usr/bin/env python3
"""Inspect comment write bodies and snapshot file inputs for verified wrappers."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import parse_qsl, unquote, urlsplit

PHRASE = re.compile(r"@codex\s+review", re.IGNORECASE)
COMMAND = re.compile(r"\s*@codex\s+review\s*", re.IGNORECASE)
GRAPHQL_COMMENTS = frozenset({
    "addComment", "addDiscussionComment", "addPullRequestReview",
    "addPullRequestReviewComment", "addPullRequestReviewThread",
    "addPullRequestReviewThreadReply", "submitPullRequestReview",
    "updateDiscussionComment", "updateIssueComment",
    "updatePullRequestReview", "updatePullRequestReviewComment",
})
GRAPHQL_TOKENS = re.compile(
    r'"""(?:\\"""|(?!"""|\\""")[\s\S])*"""|"(?:\\.|[^"\\])*"|#[^\r\n]*|[_A-Za-z][_0-9A-Za-z]*|[^\s,]'
)


class Refused(ValueError):
    pass


def graphql_comment_document(query):
    """Recognize known comment calls without interpreting GraphQL execution."""
    tokens, literals = [], []
    unsupported_literal = False
    for match in GRAPHQL_TOKENS.finditer(query):
        token = match.group()
        if token.startswith("#") or token == "\ufeff":
            continue
        if token.startswith('"""'):
            literals.append(token[3:-3].replace('\\"""', '"""'))
        elif token.startswith('"'):
            try:
                literals.append(json.loads(token))
            except ValueError:
                unsupported_literal = True
        else:
            tokens.append(token)
    comment, depth = False, 0
    for index, token in enumerate(tokens):
        operation_name = (depth == 0 and index > 0
                          and tokens[index - 1] in ("query", "mutation", "subscription"))
        if (token in GRAPHQL_COMMENTS and index + 1 < len(tokens)
                and tokens[index + 1] == "(" and not operation_name):
            comment = True
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
    if comment and unsupported_literal:
        raise Refused("Unsupported GraphQL string escape in a comment mutation; no write performed.")
    return comment, literals


def inspect(argv, role, state=None):
    original_args = list(argv)
    args = list(argv)
    bodies = []
    command_source = None
    deferred = False
    serial = 0
    cli_stdin = False

    def file_body(value, json_input=False):
        nonlocal serial, deferred
        if state is None:
            deferred = True  # Only the runtime wrapper can freeze execution bytes.
        if state is None and (value in ("-", "/dev/stdin", "/dev/fd/0") or not Path(value).is_file()):
            deferred = True
            return None, value
        try:
            raw = sys.stdin.buffer.read() if value == "-" else Path(value).read_bytes()
            text = raw.decode("utf-8")
        except (OSError, UnicodeError) as exc:
            raise Refused("Comment payload cannot be read as UTF-8; no write performed.") from exc
        parsed = json.loads(text) if json_input else text
        replacement = value
        if state is not None:
            serial += 1
            replacement = str(state / f"body-{serial}")
            with open(replacement, "xb") as output:
                os.chmod(replacement, 0o600)
                output.write(raw)
        return parsed, replacement

    def json_bodies(value, all_strings=False):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "body" and isinstance(child, str):
                    bodies.append(child)
                else:
                    json_bodies(child, all_strings)
        elif isinstance(value, list):
            for child in value:
                json_bodies(child, all_strings)
        elif all_strings and isinstance(value, str):
            bodies.append(value)

    def option(index, names):
        value = args[index]
        for name in names:
            if value == name:
                if index + 1 >= len(args):
                    raise Refused("Comment option is missing its value.")
                return args[index + 1], index + 1, "", index + 2
            if value.startswith(name + "="):
                return value[len(name) + 1:], index, name + "=", index + 1
            if len(name) == 2 and value.startswith(name) and len(value) > 2:
                return (value[3:] if value[2:3] == "=" else value[2:]), index, name, index + 1
        return None

    prefix_options = []
    prefix_reason = False

    def take_prefix(index):
        nonlocal prefix_reason
        value = args[index]
        reason = option(index, ("-r",))
        if reason and reason[0] in ("completed", "not planned", "duplicate"):
            prefix_reason = True
            prefix_options.extend(args[index:reason[3]])
            del args[index:reason[3]]
            return
        if value == "--":
            raise Refused("Place the command before the end-of-options marker.")
        # Review flags overlap closing-comment and issue-reason options.
        # Require those ambiguous prefix forms after the command verb.
        if value == "--comment" or value.startswith("--comment=") or value.startswith(("-c", "-r")):
            raise Refused("Place ambiguous comment/reason options after their command verb.")
        found = option(index, ("--method", "-X", "--field", "-F", "--raw-field", "-f", "--input",
                               "--header", "-H", "--hostname", "--jq", "-q", "--template", "-t",
                               "--preview", "-p", "--cache", "--body", "-b", "--body-file",
                               "--attach", "--reason", "--duplicate-of"))
        end = found[3] if found else index + 1
        prefix_options.extend(args[index:end])
        del args[index:end]

    # Wrappers already require a literal built-in gh payload. Allow its global
    # repository option before either command noun or verb.
    i = 1
    repo = ""
    while i < len(args):
        found = option(i, ("--repo", "-R"))
        if found:
            repo, _, _, i = found
        elif args[i] in ("pr", "issue", "api"):
            break
        elif args[i].startswith("-"):
            take_prefix(i)
        else:
            return original_args, {"guarded": False, "trigger": False}
    if i >= len(args):
        return original_args, {"guarded": False, "trigger": False}
    noun = args[i]
    i += 1
    while noun != "api" and i < len(args):
        found = option(i, ("--repo", "-R"))
        if found:
            repo, _, _, i = found
        elif args[i].startswith("-"):
            take_prefix(i)
        else:
            break
    verb = args[i] if i < len(args) else ""
    channel = ""
    pr = ""
    if noun in ("pr", "issue") and verb in ("comment", "review", "close"):
        if verb == "close" and not any(
            value in ("--comment", "-c") or value.startswith("--comment=") or re.match(r"^-d*c", value)
            for value in [*prefix_options, *args[i + 1:]]
        ):
            return original_args, {"guarded": False, "trigger": False}
        if prefix_reason:
            raise Refused("Place ambiguous reason options after their command verb.")
        channel = f"{noun}-{verb}"
        has_text = False
        i += 1
        args[i:i] = prefix_options
        while i < len(args):
            value = args[i]
            value_flags = "bFR" + ("c" if verb == "close" else "") + ("r" if channel == "issue-close" else "")
            if value.startswith("-") and not value.startswith("--") and len(value) > 2 and value[1] not in value_flags:
                raise Refused("Split clustered comment flags before writing.")
            found = option(i, ("--repo", "-R"))
            if found:
                repo, _, _, i = found
                continue
            found = option(i, ("--body-file", "-F"))
            if found:
                value, at, prefix, i = found
                cli_stdin = cli_stdin or value in ("-", "/dev/stdin", "/dev/fd/0")
                body, replacement = file_body(value)
                has_text = True
                if body is not None:
                    bodies.append(body)
                command_source = ("file", at, prefix, replacement)
                args[at] = prefix + replacement
                continue
            found = option(i, ("--body", "-b", "--attach") + (("--comment", "-c") if verb == "close" else ()))
            if found:
                value, at, prefix, end = found
                attachment = args[i].startswith("--attach")
                command_source = ("attachment" if attachment else "inline", at, prefix, "")
                has_text = has_text or not attachment
                i = end
                bodies.append(value)
                continue
            if value in ("--editor", "-e", "--web", "-w"):
                raise Refused("Materialize comment text before using the verified wrapper.")
            if not value.startswith("-") and not pr:
                pr = value
            i += 1
        if verb == "close" and not any(bodies) and not deferred:
            return original_args, {"guarded": False, "trigger": False}
        if verb != "close" and not has_text and not deferred and "--delete-last" not in args:
            if channel != "pr-review" or not any(x in args for x in ("--approve", "-a")):
                raise Refused("Provide an explicit comment body or body file before writing.")
    elif noun == "api":
        args[i:i] = prefix_options
        endpoint = ""
        method = ""
        fields = []
        inputs = []
        while i < len(args):
            value = args[i]
            if value.startswith("-") and not value.startswith("--") and len(value) > 2 and value[1] not in "fFHqtpXR":
                raise Refused("Split clustered API flags before writing.")
            found = option(i, ("--method", "-X"))
            if found:
                method, _, _, i = found
                continue
            found = option(i, ("--field", "-F", "--raw-field", "-f"))
            if found:
                value, at, prefix, end = found
                typed = args[i].startswith(("--field", "-F"))
                fields.append((value, at, prefix, typed))
                i = end
                continue
            found = option(i, ("--input",))
            if found:
                value, at, prefix, i = found
                inputs.append((value, at, prefix))
                continue
            found = option(i, ("--header", "-H", "--hostname", "--jq", "-q", "--template", "-t", "--preview", "-p", "--cache"))
            if found:
                i = found[3]
                continue
            if not args[i].startswith("-") and not endpoint:
                endpoint = args[i]
            i += 1
        path = unquote(urlsplit(endpoint).path).lstrip("/")
        method = method.upper() if method else ("POST" if fields or inputs else "GET")
        if path.rstrip("/") == "graphql":
            channel = "graphql-comment"
            queries = []
            for key, value in parse_qsl(urlsplit(endpoint).query, keep_blank_values=True):
                bodies.append(value)
                if key == "query":
                    queries.append(value)
                elif key == "variables":
                    json_bodies(json.loads(value), all_strings=True)
            for value, at, prefix, typed in fields:
                key, separator, body = value.partition("=")
                if not separator:
                    if len(key) > 2 and key.endswith("[]"):
                        continue  # gh's valueless empty array has no body text.
                    raise Refused("GraphQL fields require an explicit key=value.")
                if typed and body.startswith("@"):
                    body, replacement = file_body(body[1:])
                    args[at] = prefix + key + "=@" + replacement
                if body is not None:
                    bodies.append(body)
                    if key == "query":
                        queries.append(body)
            for value, at, prefix in inputs:
                payload, replacement = file_body(value, json_input=True)
                args[at] = prefix + replacement
                if payload is None:
                    continue
                if not isinstance(payload, dict):
                    raise Refused("GraphQL input must be a JSON object.")
                json_bodies(payload, all_strings=True)
                if "query" in payload:
                    if not isinstance(payload["query"], str):
                        raise Refused("GraphQL query must be a string.")
                    queries.append(payload["query"])
            comment = False
            for query in queries:
                writes_comment, literals = graphql_comment_document(query)
                comment = comment or writes_comment
                bodies.extend(literals)
            if not comment:
                # Freeze even read inputs: a later file edit cannot turn the
                # inspected query into a comment mutation before execution.
                return args, {"guarded": deferred, "trigger": False, "deferred": deferred}
            # Raw GraphQL is never the canonical requester's authorized CLI
            # comment channel, even when its body is the complete command.
        elif method not in ("POST", "PATCH", "PUT") or not re.fullmatch(
            r"repos/[^/]+/[^/]+/(?:issues/(?:[0-9]+/comments|comments/[0-9]+)|pulls/(?:[0-9]+/(?:comments(?:/[0-9]+/replies)?|reviews(?:/[0-9]+(?:/events)?)?)|comments/[0-9]+))", path
        ):
            return original_args, {"guarded": False, "trigger": False}
        if channel != "graphql-comment":
            channel = "api-comment"
            for value, at, prefix, typed in fields:
                key, separator, body = value.partition("=")
                if not separator or not re.search(r"(?:^body$|\[body\]$)", key):
                    continue
                if typed and body.startswith("@"):
                    body, replacement = file_body(body[1:])
                    args[at] = prefix + key + "=@" + replacement
                if body is not None:
                    bodies.append(body)
            for value, at, prefix in inputs:
                body, replacement = file_body(value, json_input=True)
                if body is not None:
                    json_bodies(body)
                args[at] = prefix + replacement
    else:
        return original_args, {"guarded": False, "trigger": False}

    hits = [body for body in bodies if PHRASE.search(body)]
    metadata = {"guarded": True, "trigger": False, "deferred": deferred, "cli_stdin": cli_stdin}
    if not hits:
        return args, metadata
    if len(bodies) != 1 or not COMMAND.fullmatch(hits[0]):
        raise Refused("Reword the comment: reserved Codex trigger text is not allowed in prose or code fences.")
    if role != "author" or channel != "pr-comment" or os.environ.get("MERGEPATH_CODEX_TRIGGER_WRITE") != "1":
        raise Refused("Use scripts/codex-review-request.sh for the reserved review command.")
    head = os.environ.get("MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD", "")
    if not re.fullmatch(r"[0-9a-f]{40}", head) or not re.fullmatch(r"[1-9][0-9]*", pr) or not re.fullmatch(r"[^/\s]+/[^/\s]+", repo):
        raise Refused("Canonical Codex request context is missing its repository, PR or full head.")
    if command_source is None or command_source[0] == "attachment":
        raise Refused("The canonical requester must supply its complete command as comment text.")
    # Canonical bytes keep every accepted trigger visible to the existing
    # exact-body request counter, including callers supplying whitespace.
    kind, at, prefix, snapshot = command_source
    if kind == "inline":
        args[at] = prefix + "@codex review"
    elif state is not None:
        Path(snapshot).write_bytes(b"@codex review")
    metadata.update(trigger=True, repo=repo, pr=int(pr), head=head)
    return args, metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", choices=("author", "reviewer", "hook"), required=True)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    opts = parser.parse_args()
    argv = opts.argv[1:] if opts.argv[:1] == ["--"] else opts.argv
    try:
        args, metadata = inspect(argv, opts.role, opts.state_dir)
        if opts.state_dir is not None:
            (opts.state_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            (opts.state_dir / "argv").write_bytes(b"".join(os.fsencode(arg) + b"\0" for arg in args))
        else:
            print(json.dumps(metadata))
    except (Refused, ValueError, OSError) as exc:
        print(f"comment-trigger-guard: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
