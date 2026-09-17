#!/usr/bin/env node
// Hub-only source for the propagated standalone pr-body-contract.mjs. Rebuild with:
// node scripts/lib/pr-body-contract.bundle/rebuild.mjs --write

import { readFileSync } from 'node:fs';
import { fromMarkdown } from 'mdast-util-from-markdown';
import { gfmFromMarkdown } from 'mdast-util-gfm';
import { gfm } from 'micromark-extension-gfm';

const AUTHORING_AGENT_RE = /^Authoring-Agent:\s*(.*?)\s*$/i;
const SELF_REVIEW_RE = /^##[ \t]+Self-Review(?:[ \t]+#*)?[ \t]*$/i;
// A GFM footnote definition is a container exactly as a list item is: an
// unindented, non-interrupting line after `[^x]: note` is a lazy continuation
// of the definition's paragraph, and GitHub renders it inside the footnote --
// or, with nothing referencing that footnote, does not render it at all.
// Omitting the node type let such a line read as a live top-level
// declaration, which is identity spoofing. The parser this file replaces has
// the same hole; it is repaired here rather than carried forward, because
// this contract's stated guarantee is that GFM membership decides
// top-level-ness, and this parser builds the node and then ignored it.
// GFM table cells are containers for the same reason: `header` / `| --- |` /
// `Authoring-Agent: codex` puts the declaration in a tableCell, which GitHub
// renders inside a `<td>`. The parser this file replaces accepts it too, so
// this is a repair rather than a regression. The set below was checked by
// sweeping every construct that can hold a marker line -- blockquote, list
// item, list lazy continuation, footnote definition, table cell in both piped
// and unpiped form, task list item, and a blockquote nested in a list item --
// against GitHub's renderer; the unpiped table cell was the only disagreement.
const CONTAINERS = new Set([
  'blockquote', 'list', 'listItem', 'footnoteDefinition',
  'table', 'tableRow', 'tableCell',
]);

function rawLines(body) {
  return body.split(/\r\n|\r|\n/);
}

function gfmMembershipExtensions() {
  // This CLI reads source positions and block membership; it never renders or
  // consumes GFM's rewritten inline link nodes. Keep every GFM tokenizer and
  // mdast enter/exit handler, but omit post-parse transforms such as autolink
  // linkification, whose recursive visitor cannot affect this contract.
  return gfmFromMarkdown().map((extension) => ({ ...extension, transforms: [] }));
}

function covers(position, line, column = 1) {
  if (!position) return false;
  const startsBefore =
    position.start.line < line ||
    (position.start.line === line && position.start.column <= column);
  const endsAfter =
    position.end.line > line ||
    (position.end.line === line && position.end.column >= column);
  return startsBefore && endsAfter;
}

function collect(root) {
  const entries = [];
  const stack = [{ node: root, isInContainer: false }];
  while (stack.length > 0) {
    const { node, isInContainer } = stack.pop();
    const entry = {
      node,
      isInContainer: isInContainer || CONTAINERS.has(node.type),
    };
    entries.push(entry);
    const children = node.children ?? [];
    for (let index = children.length - 1; index >= 0; index -= 1) {
      stack.push({ node: children[index], isInContainer: entry.isInContainer });
    }
  }
  return entries;
}

// The existing contract removes HTML comments before checking marker syntax.
// Here the mdast html-node positions identify only real comments: a comment
// spelling inside fenced or inline code never appears as html and cannot alter
// the marker text.
function visibleLinesAfterComments(body, lines, entries) {
  const characters = body.split('');
  const discardLines = new Set();
  // micromark skips a leading BOM before assigning source positions. Keep the
  // raw body for the strict marker syntax, but translate html-node coordinates
  // back to that body before removing real HTML comments.
  const bomOffset = body.charCodeAt(0) === 0xFEFF ? 1 : 0;
  for (const { node } of entries) {
    const position = node.type === 'html' ? node.position : null;
    if (!position || !node.value?.startsWith('<!--')) continue;
    const startOffset = position.start.offset + bomOffset;
    const endOffset = position.end.offset + bomOffset;
    if (body.slice(startOffset, startOffset + 4) !== '<!--') continue;
    for (let offset = startOffset; offset < endOffset; offset += 1) {
      if (characters[offset] !== '\n' && characters[offset] !== '\r') characters[offset] = '';
    }
    const firstLineOffset = position.start.line === 1 ? bomOffset : 0;
    const prefixLength = position.start.column - 1 + firstLineOffset;
    const prefix = lines[position.start.line - 1].slice(firstLineOffset, prefixLength);
    if (/^ {0,3}$/.test(prefix)) {
      for (let line = position.start.line; line <= position.end.line; line += 1) discardLines.add(line);
    }
  }
  const visibleLines = rawLines(characters.join(''));
  return visibleLines.map((line, index) => discardLines.has(index + 1) ? null : line);
}

export function parsePrBodyContract(body) {
  const lines = rawLines(body);
  const entries = collect(fromMarkdown(body, {
    extensions: [gfm()],
    mdastExtensions: gfmMembershipExtensions(),
  }));
  const visibleLines = visibleLinesAfterComments(body, lines, entries);
  const authorValues = [];

  for (let index = 0; index < lines.length; index += 1) {
    const match = visibleLines[index]?.match(AUTHORING_AGENT_RE);
    if (!match) continue;
    const text = entries.find((entry) =>
      entry.node.type === 'text' && covers(entry.node.position, index + 1),
    );
    if (text && !text.isInContainer) authorValues.push(match[1]);
  }

  const hasSelfReview = entries.some((entry) => {
    const { node } = entry;
    return node.type === 'heading' &&
      node.depth === 2 &&
      node.position?.start.column === 1 &&
      SELF_REVIEW_RE.test(visibleLines[node.position.start.line - 1] ?? '') &&
      !entry.isInContainer;
  });

  const author =
    authorValues.length === 1 && /^[A-Za-z0-9_-]+$/.test(authorValues[0])
      ? authorValues[0].toLowerCase()
      : '';
  return { author, authorCount: authorValues.length, hasSelfReview };
}

const mode = process.argv[2];
const contract = parsePrBodyContract(readFileSync(0, 'utf8'));
switch (mode) {
  case '--author':
    if (contract.author !== '') process.stdout.write(`${contract.author}\n`);
    break;
  case '--author-count':
    process.stdout.write(`${contract.authorCount}\n`);
    break;
  case '--has-self-review':
    process.exitCode = contract.hasSelfReview ? 0 : 1;
    break;
  case '--json':
    process.stdout.write(`${JSON.stringify(contract)}\n`);
    break;
  default:
    process.stderr.write(
      'usage: pr-body-contract.mjs (--author|--author-count|--has-self-review|--json) < pr-body.md\n',
    );
    process.exitCode = 2;
}
