#!/usr/bin/env python3
"""Render-preserving Markdown prose reflow — unwrap fixed-column paragraphs.

Converts manually hard-wrapped Markdown *prose* (several physical lines per
paragraph, broken mid-clause at ~72 columns) into soft-wrapped prose (one
physical line per paragraph; the renderer wraps). GitHub-flavored Markdown
collapses single newlines inside a paragraph to spaces, so this changes the
*source* only — the rendered output is identical.

This is deliberately NOT a general Markdown formatter. It removes ONLY
intra-paragraph soft-break newlines. It does not touch:

  - fenced or indented code blocks,
  - GFM tables (parsed as table blocks, emitted verbatim),
  - YAML front matter (stripped and re-attached byte-for-byte),
  - link reference definitions,
  - list / block-quote markers and structure,
  - GitHub alert blockquotes (``> [!NOTE]`` …) and GFM footnote definitions
    (``[^label]:``) — left verbatim so their markers keep their own line
    (see ``_SKIP_JOIN_FIRST_LINE``),
  - HTML blocks,
  - thematic breaks, headings, inline emphasis/code/link markup.

How it stays safe
-----------------
1. Markdown-AST-aware, not regex: the file is parsed with markdown-it-py
   (the CommonMark parser mdformat and — closely — GitHub use), with the
   GFM ``table`` rule enabled so table rows are never mistaken for prose.
   Only ``paragraph`` blocks are rewritten; every other source line is
   copied byte-for-byte. The parser is CommonMark + tables, so GFM-only
   *block* extensions it cannot model are guarded at the source rather than
   relied on the render check to catch: GitHub alerts and footnote
   definitions are skipped by ``_SKIP_JOIN_FIRST_LINE``. (Task lists are
   list items and reflow safely; ``$$`` math and ``:::`` containers are
   absent from the in-scope files — add a guard if one is introduced.)
2. Fail-closed render check: after reflow, the original and reflowed bodies
   are each rendered to HTML and compared with intra-text whitespace
   normalized. If the render differs in any way other than the intended
   soft-break→space collapse, the reflow is rejected (``ReflowError``) and
   the file is left untouched. A lost hard line break, a corrupted table,
   or a mis-joined list item all trip this check.

Only markdown-it-py is required (no plugins) — front matter is handled
without a plugin so the dependency surface stays a single pinned package.

CLI
---
  md_reflow.py --check  FILE...   exit 1 if any FILE is not already reflowed
  md_reflow.py --write  FILE...   rewrite each FILE in place (idempotent)
  md_reflow.py --diff   FILE...   print a unified diff of what --write would do

Exit codes: 0 = clean / done, 1 = needs-reflow (``--check``) or write failure,
2 = usage error, 3 = a file failed the fail-closed render check.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

try:
    from markdown_it import MarkdownIt
except ModuleNotFoundError as exc:  # pragma: no cover - env guard
    sys.stderr.write(
        "md_reflow: markdown-it-py is required "
        "(pip install 'markdown-it-py==4.2.0')\n"
    )
    raise SystemExit(2) from exc


class ReflowError(RuntimeError):
    """A reflow would have changed the rendered output — refuse it."""


# A single parser instance, reused for both reflow and the render check.
# CommonMark preset + the GFM ``table`` block rule. ``table`` MUST be enabled
# or a pipe table's rows parse as a lazy paragraph and get joined — the exact
# corruption this tool must never cause. No linkify (optional dependency) and
# no other GFM inline rules are needed: they do not affect block structure and
# both sides of the render check use this same instance, so the comparison is
# self-consistent regardless.
_MD = MarkdownIt("commonmark").enable("table")

_WS_RUN = re.compile(r"\s+")

# Source guards for GitHub-flavored *block* extensions the CommonMark parser
# above cannot model — so the render check (also CommonMark) cannot be relied
# on to catch their corruption. Rather than trust the check, any paragraph
# whose FIRST line is one of these markers is left exactly as written (never
# joined). Two constructs qualify:
#
#   * GitHub alert blockquotes — `> [!NOTE]`, `> [!WARNING]`, … The `[!TYPE]`
#     marker MUST stay on its own line; joining `[!NOTE]\n<body>` onto one line
#     silently downgrades the alert to a plain blockquote on GitHub. (A blank
#     line after the marker already splits it into its own single-line
#     paragraph, which is never joined; only the no-blank-line form is at risk,
#     and this guard covers it.)
#   * GFM footnote definitions — `[^label]:` …  Joining a footnote definition
#     is in fact render-preserving under a footnote-aware parser, but the
#     CommonMark check does not model footnotes, so it is guarded here too:
#     defensively leaving the definition intact keeps the tool correct without
#     depending on the check to model an extension it cannot see.
#
# The alert type is matched case-insensitively and the marker must be alone on
# its line, per GFM alert syntax. `$$` math blocks and `:::` containers are not
# GitHub-rendered in this repo's prose and are absent from the in-scope files;
# if one is ever added, add its marker here (or model it in the render check).
_SKIP_JOIN_FIRST_LINE = re.compile(
    r"^(?:"
    r"\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$"  # GitHub alert marker
    r"|\[\^[^\]]+\]:"                                    # GFM footnote definition
    r")",
    re.IGNORECASE,
)


def split_front_matter(text: str) -> tuple[str, str]:
    """Split leading YAML front matter from the body.

    Returns ``(front_matter, body)`` where ``front_matter`` includes its
    closing fence and trailing newline (or is empty). Front matter is only
    recognized as a ``---`` fence on the very first line closed by a line that
    is exactly ``---`` or ``...``. It is returned verbatim and never reflowed.
    """
    if not text.startswith("---\n") and text != "---":
        return "", text
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return "", text
    for i in range(1, len(lines)):
        if lines[i] in ("---", "..."):
            # Everything through line i (inclusive) is front matter. Keep the
            # newline that followed the closing fence with the front matter so
            # the body starts at the next content line.
            fm = "\n".join(lines[: i + 1]) + "\n"
            body = "\n".join(lines[i + 1 :])
            return fm, body
    return "", text


def _render(markdown: str) -> str:
    return _MD.render(markdown)


def _normalized_render(markdown: str) -> str:
    """Render to HTML with inter-token whitespace collapsed.

    A soft break renders as ``\\n`` inside the paragraph HTML; the joined form
    renders as a space. Collapsing whitespace runs makes those two equivalent
    while still catching any *structural* difference (a dropped ``<br>``, a
    table turned into a paragraph, a mangled list).
    """
    return _WS_RUN.sub(" ", _render(markdown)).strip()


def _paragraph_replacements(body: str) -> dict[int, tuple[int, str]]:
    """Map each reflowable paragraph's start line to ``(end_line, one_line)``.

    Keys/values are 0-based line indices into ``body.split("\\n")``; ``end_line``
    is exclusive. A paragraph is reflowed only when its first source line ends
    with the parser's clean inline content for that paragraph — that anchors the
    block prefix (indentation, ``>`` quote markers, list bullet) so it is
    preserved on the joined line. Anything ambiguous is skipped (left as-is).
    """
    lines = body.split("\n")
    tokens = _MD.parse(body)
    out: dict[int, tuple[int, str]] = {}

    for idx, tok in enumerate(tokens):
        if tok.type != "paragraph_open" or tok.map is None:
            continue
        start, end = tok.map  # end exclusive
        # The inline token carrying the paragraph's text follows immediately.
        inline = tokens[idx + 1] if idx + 1 < len(tokens) else None
        if inline is None or inline.type != "inline":
            continue
        content = inline.content
        if "\n" not in content:
            continue  # already a single logical line — nothing to join
        # A hard line break (trailing two spaces / backslash) renders as <br>.
        # Joining across it would drop the break, so leave such a paragraph
        # exactly as written. (The render check below is the final backstop.)
        if any(child.type == "hardbreak" for child in (inline.children or [])):
            continue
        segs = content.split("\n")
        first_seg = segs[0]
        # A GitHub-only block-extension marker (alert / footnote definition)
        # must stay on its own line; never join it into the following body.
        if _SKIP_JOIN_FIRST_LINE.match(first_seg):
            continue
        first_line = lines[start]
        # Anchor the block prefix: the paragraph text is the tail of the first
        # physical line. If it is not (trailing whitespace the parser dropped,
        # an unusual construct), skip rather than risk a bad join.
        if not first_seg or not first_line.endswith(first_seg):
            continue
        prefix = first_line[: len(first_line) - len(first_seg)]
        joined = prefix + content.replace("\n", " ")
        if joined == "\n".join(lines[start:end]):
            continue  # no-op
        out[start] = (end, joined)
    return out


def reflow_body(body: str) -> str:
    replacements = _paragraph_replacements(body)
    if not replacements:
        return body
    lines = body.split("\n")
    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        if i in replacements:
            end, joined = replacements[i]
            out.append(joined)
            i = end
        else:
            out.append(lines[i])
            i += 1
    return "\n".join(out)


def reflow_text(text: str) -> str:
    """Return ``text`` with prose paragraphs unwrapped; fail-closed on change.

    Raises :class:`ReflowError` if the reflow would alter the rendered HTML in
    any way beyond the intended soft-break→space collapse.
    """
    front_matter, body = split_front_matter(text)
    new_body = reflow_body(body)
    if new_body == body:
        return text
    if _normalized_render(body) != _normalized_render(new_body):
        raise ReflowError("reflow would change rendered output")
    return front_matter + new_body


def _iter_targets(paths: list[str]) -> list[Path]:
    return [Path(p) for p in paths]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="md_reflow",
        description="Render-preserving Markdown prose reflow (unwrap paragraphs).",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="exit 1 if any file needs reflow")
    mode.add_argument("--write", action="store_true", help="rewrite files in place")
    mode.add_argument("--diff", action="store_true", help="print unified diff of --write")
    parser.add_argument("files", nargs="+", help="Markdown files to process")
    args = parser.parse_args(argv)

    needs_reflow: list[str] = []
    failures: list[str] = []
    render_errors: list[str] = []

    for path in _iter_targets(args.files):
        try:
            original = path.read_text(encoding="utf-8")
        except OSError as exc:
            sys.stderr.write(f"md_reflow: cannot read {path}: {exc}\n")
            failures.append(str(path))
            continue
        try:
            reflowed = reflow_text(original)
        except ReflowError as exc:
            sys.stderr.write(f"md_reflow: REFUSED {path}: {exc}\n")
            render_errors.append(str(path))
            continue

        if reflowed == original:
            continue

        if args.check:
            needs_reflow.append(str(path))
        elif args.diff:
            diff = difflib.unified_diff(
                original.splitlines(keepends=True),
                reflowed.splitlines(keepends=True),
                fromfile=f"a/{path}",
                tofile=f"b/{path}",
            )
            sys.stdout.writelines(diff)
        elif args.write:
            try:
                path.write_text(reflowed, encoding="utf-8")
            except OSError as exc:
                sys.stderr.write(f"md_reflow: cannot write {path}: {exc}\n")
                failures.append(str(path))
                continue
            sys.stderr.write(f"md_reflow: reflowed {path}\n")

    if render_errors:
        sys.stderr.write(
            "md_reflow: "
            + str(len(render_errors))
            + " file(s) failed the fail-closed render check (left untouched)\n"
        )
        return 3
    if failures:
        return 1
    if args.check and needs_reflow:
        sys.stderr.write(
            "md_reflow: "
            + str(len(needs_reflow))
            + " file(s) need reflow (run scripts/lint-md-prose-wrap.sh --write):\n"
        )
        for f in needs_reflow:
            sys.stderr.write(f"  {f}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
