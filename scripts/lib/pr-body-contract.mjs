#!/usr/bin/env node

import { readFileSync } from 'node:fs';

/**
 * Read the repository's deliberately strict PR-body contract without runtime
 * packages. Contract markers must be plain top-level Markdown, never hidden in
 * comments, fences, indented code, or raw HTML blocks.
 */
export function parsePrBodyContract(body) {
  const authorValues = [];
  let hasSelfReview = false;
  let fence = null;
  let inComment = false;
  let htmlBlock = null;
  let codeSpanTicks = null;

  const lines = body.split(/\r?\n/);
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const rawLine = lines[lineIndex];
    // Four spaces (or a tab) means an indented code block, and an indented
    // backtick run is CODE, not a fence delimiter. trimStart() erased that
    // distinction, so `    \u0060\u0060\u0060` opened a fence that never closed and the
    // rest of the body -- including valid top-level markers -- was discarded.
    // A fence delimiter may be indented at most three spaces.
    const indentedCode = /^(?: {4}|\t)/.test(rawLine);
    const fenceLine = rawLine.trimStart();
    if (fence != null) {
      if (!indentedCode) {
        const closing = fenceLine.match(/^(`{3,}|~{3,})[ \t]*$/);
        if (closing && closing[1][0] === fence.marker && closing[1].length >= fence.length) {
          fence = null;
        }
      }
      continue;
    }

    // Inline code spans can cross line endings. While one is open, block
    // syntax and contract-looking text are literal code, including comment or
    // HTML delimiters. Unmatched runs remain literal; scanCodeSpanTicks looks
    // ahead for an exact-length closer before it opens a span.
    if (codeSpanTicks != null) {
      codeSpanTicks = scanCodeSpanTicks(rawLine, codeSpanTicks, lines, lineIndex);
      continue;
    }

    // Comment and raw-HTML state outrank fence-looking content while those
    // blocks are active. Conversely, comment delimiters inside an active
    // fenced code block above are literal code and never mutate inComment.
    if (inComment) {
      stripHtmlComments(rawLine, (state) => {
        inComment = state;
      }, true);
      continue;
    }

    if (htmlBlock != null) {
      if (htmlBlock === 'blank') {
        if (rawLine.trim() === '') htmlBlock = null;
      } else if (htmlBlock === 'processing') {
        if (rawLine.includes('?>')) htmlBlock = null;
      } else if (htmlBlock === 'cdata') {
        if (rawLine.includes(']]>')) htmlBlock = null;
      } else if (htmlBlock === 'declaration') {
        if (rawLine.includes('>')) htmlBlock = null;
      } else if (new RegExp(`</${htmlBlock}\\s*>`, 'i').test(rawLine)) {
        htmlBlock = null;
      }
      continue;
    }

    if (indentedCode) continue;

    const opening =
      fenceLine.match(/^(`{3,})([^`]*)$/) ?? fenceLine.match(/^(~{3,})(.*)$/);
    if (opening) {
      fence = { marker: opening[1][0], length: opening[1].length };
      continue;
    }

    let line = stripHtmlComments(rawLine, (state) => {
      inComment = state;
    }, false);
    if (line == null) continue;

    const nextCodeSpanTicks = scanCodeSpanTicks(line, null, lines, lineIndex);
    if (nextCodeSpanTicks != null) {
      codeSpanTicks = nextCodeSpanTicks;
      continue;
    }

    const rawTag = line.match(/^ {0,3}<(script|pre|style|textarea)(?:\s|>|$)/i);
    if (rawTag) {
      if (!new RegExp(`</${rawTag[1]}\\s*>`, 'i').test(line)) {
        htmlBlock = rawTag[1].toLowerCase();
      }
      continue;
    }
    if (/^ {0,3}<\?/.test(line)) {
      if (!line.includes('?>')) htmlBlock = 'processing';
      continue;
    }
    if (/^ {0,3}<!\[CDATA\[/.test(line)) {
      if (!line.includes(']]>')) htmlBlock = 'cdata';
      continue;
    }
    if (/^ {0,3}<![A-Z]/.test(line)) {
      if (!line.includes('>')) htmlBlock = 'declaration';
      continue;
    }
    // CommonMark HTML block condition 6 uses a fixed tag-name list and does
    // not require a closing `>`: `<div` at end of line starts a raw block that
    // runs until the next blank line. Keep this distinct from condition 7's
    // complete generic-tag rule so `<foo` remains ordinary prose.
    if (/^ {0,3}<\/?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[ \t]|\/?>|$)/i.test(line)) {
      htmlBlock = 'blank';
      continue;
    }
    // Tag NAME then a boundary, not any angle-bracketed token: an autolink
    // such as <https://example.com> is inline content, and treating it as a
    // raw HTML block swallowed every line up to the next blank one -- hiding
    // the very markers this parser exists to find.
    if (/^ {0,3}<\/?[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[^>]*|[ \t]*\/?)>/.test(line)) {
      htmlBlock = line.trim() === '' ? null : 'blank';
      continue;
    }

    if (/^(?: {4}|\t)/.test(line)) continue;
    // The contract is intentionally stricter than CommonMark's permissive
    // indentation: declarations must begin at column zero. A one-to-three
    // space prefix can be list continuation content, where the rendered
    // declaration is nested rather than top-level.
    if (/^##[ \t]+Self-Review(?:[ \t]+#*)?[ \t]*$/i.test(line)) {
      hasSelfReview = true;
      continue;
    }

    const authorMatch = line.match(/^Authoring-Agent:\s*(.*?)\s*$/i);
    if (authorMatch) authorValues.push(authorMatch[1]);
  }

  const author =
    authorValues.length === 1 && /^[A-Za-z0-9_-]+$/.test(authorValues[0])
      ? authorValues[0].toLowerCase()
      : '';

  return { author, authorCount: authorValues.length, hasSelfReview };
}

function stripHtmlComments(line, setState, initialState) {
  let result = '';
  let cursor = 0;
  let inComment = initialState;
  const discardLine = initialState || /^ {0,3}<!--/.test(line);

  while (cursor < line.length) {
    if (inComment) {
      const end = line.indexOf('-->', cursor);
      if (end === -1) {
        setState(true);
        return result || null;
      }
      cursor = end + 3;
      inComment = false;
      continue;
    }

    const start = line.indexOf('<!--', cursor);
    if (start === -1) {
      result += line.slice(cursor);
      break;
    }
    result += line.slice(cursor, start);
    cursor = start + 4;
    inComment = true;
  }

  setState(inComment);
  return discardLine ? null : result;
}

function scanCodeSpanTicks(line, activeTicks, lines, lineIndex) {
  let cursor = 0;
  let ticks = activeTicks;
  while (cursor < line.length) {
    if (line[cursor] !== '`') {
      cursor += 1;
      continue;
    }
    let end = cursor + 1;
    while (end < line.length && line[end] === '`') end += 1;
    const runLength = end - cursor;
    if (ticks == null) {
      // An unmatched backtick run is literal text, not a code-span opener.
      // Look ahead before changing state so a malformed fence-info line such
      // as ```foo`bar cannot suppress otherwise-visible declarations.
      if (hasMatchingCodeSpanRun(lines, lineIndex, end, runLength)) ticks = runLength;
    }
    else if (runLength === ticks) ticks = null;
    cursor = end;
  }
  return ticks;
}

function hasMatchingCodeSpanRun(lines, lineIndex, column, runLength) {
  for (let index = lineIndex; index < lines.length; index += 1) {
    const candidate = index === lineIndex ? lines[index].slice(column) : lines[index];
    for (const match of candidate.matchAll(/`+/g)) {
      if (match[0].length === runLength) return true;
    }
  }
  return false;
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
