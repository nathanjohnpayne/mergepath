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

function collect(node, ancestors = [], entries = []) {
  const entry = { node, ancestors: [...ancestors, node.type] };
  entries.push(entry);
  for (const child of node.children ?? []) collect(child, entry.ancestors, entries);
  return entries;
}

function hasContainerAncestor(entry) {
  return entry.ancestors.some((type) => CONTAINERS.has(type));
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
    mdastExtensions: [gfmFromMarkdown()],
  }));
  const visibleLines = visibleLinesAfterComments(body, lines, entries);
  const authorValues = [];

  for (let index = 0; index < lines.length; index += 1) {
    const match = visibleLines[index]?.match(AUTHORING_AGENT_RE);
    if (!match) continue;
    const text = entries.find((entry) =>
      entry.node.type === 'text' && covers(entry.node.position, index + 1),
    );
    if (text && !hasContainerAncestor(text)) authorValues.push(match[1]);
  }

  const hasSelfReview = entries.some((entry) => {
    const { node } = entry;
    return node.type === 'heading' &&
      node.depth === 2 &&
      node.position?.start.column === 1 &&
      SELF_REVIEW_RE.test(visibleLines[node.position.start.line - 1] ?? '') &&
      !hasContainerAncestor(entry);
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
