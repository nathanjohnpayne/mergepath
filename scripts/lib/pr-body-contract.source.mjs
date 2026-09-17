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
// or, with no reference to the footnote, does not render it at all. Omitting
// the node type here let such a line read as a live top-level declaration,
// which is identity spoofing (Phase 4b P0, and Codex finding 4012896772
// before it). The parser this file replaces has the same hole; it is repaired
// here rather than carried forward, because this contract's stated guarantee
// is that GFM membership decides top-level-ness.
const CONTAINERS = new Set(['blockquote', 'list', 'listItem', 'footnoteDefinition']);

// A resource-safety ceiling on same-line list nesting. See boundedListNesting
// below for why it exists and what it does NOT claim.
const MAX_LIST_DEPTH = 64;

// The codes micromark registers the CommonMark `list` construct under: the
// three bullet markers and the ten digits that can open an ordered item.
const LIST_MARKER_CODES = [42, 43, 45, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57];

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

// RESOURCE-SAFETY GUARD, not a semantic rule.
//
// micromark opens list containers without any nesting bound, and its document
// tokenizer re-shuffles its whole event array as each container opens, so a
// single line of repeated markers costs O(n^2). A 60,042-byte body of
// `'- '.repeat(30000)` does not finish in 45 seconds, while the parser this
// file replaces answers it in about 0.2 seconds -- and PR bodies are untrusted
// input that three validator invocations each re-parse. micromark 4.0.2 and
// mdast-util-from-markdown 2.0.3 are the current upstream releases and neither
// exposes a depth option, so the ceiling has to live here.
//
// The ceiling is justified ONLY as a cost bound on micromark's pathological
// same-line list nesting. It is NOT a claim that 64 levels is where list
// nesting stops meaning anything, and in particular it is NOT derived from
// GitHub's renderer: cmark-gfm does cap list nesting, but it emits sibling
// items past its cap rather than folding deeper markers into the innermost
// item, so its lazy-continuation behaviour differs from what this gate
// produces. Matching its number would not match its behaviour.
//
// Truncating nesting CAN change this contract's answers, and at small
// ceilings it does. The ceiling is therefore chosen empirically, as the point
// where a differential against an unbounded parse stops diverging, with
// margin. Over 1,277,759 generated lines (8 seeds) whose nesting straddles
// each candidate, divergences were: ceiling 20 -> 7, ceiling 24 -> 2, ceiling
// 32 -> 0, ceiling 64 -> 0. The margin is not decoration: a 10x smaller corpus
// showed ceiling 24 clean, and only the larger one exposed it. Worst-case cost
// at GitHub's 65,536-character body limit is flat from 24 to 64 (about 3.2s
// CPU on Node 22, 2.4s on Node 24, on the many-lines-at-the-ceiling shape a
// ceiling steers an adversary toward), so going lower buys nothing and 64
// takes the headroom. Every divergence observed at any ceiling was
// fail-closed -- a lost declaration, which blocks -- never fail-open.
//
// This is a gate, not a parser: the construct below never tokenizes a list. It
// runs before the upstream `list` construct at each marker code and either
// lets it run untouched, or -- past the ceiling -- vetoes it by name for
// exactly one attempt, so the marker becomes content of the innermost open
// item. A third construct registered after `list` lifts the veto in the same
// attempt, so no later sibling item can inherit it.
function boundedListNesting(limit) {
  const states = new WeakMap();

  function stateFor(self) {
    let state = states.get(self);
    if (!state) {
      state = { line: 0, depth: 0 };
      states.set(self, state);
    }
    const { line } = self.now();
    if (line !== state.line) {
      state.line = line;
      state.depth = 0;
    }
    return state;
  }

  function veto(self, on) {
    const disabled = self.parser.constructs.disable.null;
    const at = disabled.indexOf('list');
    if (on && at === -1) disabled.push('list');
    if (!on && at !== -1) disabled.splice(at, 1);
  }

  const gate = {
    name: 'boundedListGate',
    add: 'before',
    tokenize(effects, ok, nok) {
      veto(this, false);
      const state = stateFor(this);
      // A sibling item re-attempts `list` against the OPEN container's state,
      // which already carries its depth. It adds no nesting.
      const open = this.containerState._boundedListDepth;
      if (typeof open === 'number') {
        state.depth = open;
        return nok;
      }
      const depth = state.depth + 1;
      if (depth > limit) {
        veto(this, true);
        return nok;
      }
      this.containerState._boundedListDepth = depth;
      state.depth = depth;
      return nok;
    },
  };

  const lift = {
    name: 'boundedListLift',
    add: 'after',
    tokenize(effects, ok, nok) {
      veto(this, false);
      return nok;
    },
  };

  const document = {};
  for (const code of LIST_MARKER_CODES) document[code] = [gate, lift];
  return { document };
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
    extensions: [gfm(), boundedListNesting(MAX_LIST_DEPTH)],
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
