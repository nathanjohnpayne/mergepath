#!/usr/bin/env node
// Hub-only source for the propagated standalone pr-body-contract.mjs. Rebuild with:
// node scripts/lib/pr-body-contract.bundle/rebuild.mjs --write

import { readFileSync } from 'node:fs';
import { fromMarkdown } from 'mdast-util-from-markdown';
import { gfmFromMarkdown } from 'mdast-util-gfm';
import { gfm } from 'micromark-extension-gfm';

const AUTHORING_AGENT_RE = /^Authoring-Agent:\s*(.*?)\s*$/i;
const SELF_REVIEW_RE = /^##[ \t]+Self-Review(?:[ \t]+#*)?[ \t]*$/i;
const CONTAINERS = new Set(['blockquote', 'list', 'listItem']);

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
  for (const { node } of entries) {
    const position = node.type === 'html' ? node.position : null;
    if (!position || !node.value?.startsWith('<!--')) continue;
    if (body.slice(position.start.offset, position.start.offset + 4) !== '<!--') continue;
    for (let offset = position.start.offset; offset < position.end.offset; offset += 1) {
      if (characters[offset] !== '\n' && characters[offset] !== '\r') characters[offset] = '';
    }
    const prefix = lines[position.start.line - 1].slice(0, position.start.column - 1);
    if (/^ {0,3}$/.test(prefix)) {
      for (let line = position.start.line; line <= position.end.line; line += 1) discardLines.add(line);
    }
  }
  const visibleLines = characters.join('').split(/\r?\n/);
  return visibleLines.map((line, index) => discardLines.has(index + 1) ? null : line);
}

export function parsePrBodyContract(body) {
  const lines = body.split(/\r?\n/);
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
