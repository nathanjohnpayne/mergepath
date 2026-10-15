#!/usr/bin/env python3
"""Inspect comment write bodies and snapshot file inputs for verified wrappers."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

PHRASE = re.compile(r"@codex\s+review", re.IGNORECASE)
COMMAND = re.compile(r"\s*@codex\s+review\s*", re.IGNORECASE)


class Refused(ValueError):
    pass


def inspect(argv, role, state=None):
    args = list(argv)
    bodies = []
    command_source = None
    deferred = False
    serial = 0
    cli_stdin = False

    def file_body(value, json_input=False):
        nonlocal serial, deferred
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

    def json_bodies(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "body" and isinstance(child, str):
                    bodies.append(child)
                else:
                    json_bodies(child)
        elif isinstance(value, list):
            for child in value:
                json_bodies(child)

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
            i += 1
        else:
            return args, {"guarded": False, "trigger": False}
    if i >= len(args):
        return args, {"guarded": False, "trigger": False}
    noun = args[i]
    i += 1
    while noun != "api" and i < len(args):
        found = option(i, ("--repo", "-R"))
        if not found:
            break
        repo, _, _, i = found
    verb = args[i] if i < len(args) else ""
    channel = ""
    pr = ""
    if noun in ("pr", "issue") and verb in ("comment", "review"):
        channel = f"{noun}-{verb}"
        has_text = False
        i += 1
        while i < len(args):
            value = args[i]
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
            found = option(i, ("--body", "-b", "--attach"))
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
        if not has_text and not deferred and "--delete-last" not in args:
            if channel != "pr-review" or not any(x in args for x in ("--approve", "-a")):
                raise Refused("Provide an explicit comment body or body file before writing.")
    elif noun == "api":
        endpoint = ""
        method = ""
        fields = []
        inputs = []
        while i < len(args):
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
        if method not in ("POST", "PATCH", "PUT") or not re.fullmatch(
            r"repos/[^/]+/[^/]+/(?:issues/(?:[0-9]+/comments|comments/[0-9]+)|pulls/(?:[0-9]+/(?:comments(?:/[0-9]+/replies)?|reviews(?:/[0-9]+(?:/events)?)?)|comments/[0-9]+))", path
        ):
            return args, {"guarded": False, "trigger": False}
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
        return args, {"guarded": False, "trigger": False}

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
