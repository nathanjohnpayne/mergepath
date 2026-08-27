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

  for (const rawLine of body.split(/\r?\n/)) {
    let line = stripHtmlComments(rawLine, (state) => {
      inComment = state;
    }, inComment);
    if (line == null) continue;

    const fenceLine = stripContainerPrefix(line).trimStart();
    if (fence != null) {
      const closing = fenceLine.match(/^(`{3,}|~{3,})\s*$/);
      if (closing && closing[1][0] === fence.marker && closing[1].length >= fence.length) {
        fence = null;
      }
      continue;
    }

    const opening = fenceLine.match(/^(`{3,}|~{3,})(.*)$/);
    if (opening) {
      fence = { marker: opening[1][0], length: opening[1].length };
      continue;
    }

    if (htmlBlock != null) {
      if (htmlBlock === 'blank') {
        if (line.trim() === '') htmlBlock = null;
      } else if (htmlBlock === 'processing') {
        if (line.includes('?>')) htmlBlock = null;
      } else if (htmlBlock === 'cdata') {
        if (line.includes(']]>')) htmlBlock = null;
      } else if (htmlBlock === 'declaration') {
        if (line.includes('>')) htmlBlock = null;
      } else if (new RegExp(`</${htmlBlock}\\s*>`, 'i').test(line)) {
        htmlBlock = null;
      }
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
    if (/^ {0,3}<\/?[A-Za-z][^>]*(?:>|$)/.test(line)) {
      htmlBlock = line.trim() === '' ? null : 'blank';
      continue;
    }

    if (/^(?: {4}|\t)/.test(line)) continue;
    if (/^ {0,3}##[ \t]+Self-Review(?:[ \t]+#*)?[ \t]*$/i.test(line)) {
      hasSelfReview = true;
      continue;
    }

    const authorMatch = line.match(/^ {0,3}Authoring-Agent:\s*(.*?)\s*$/i);
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

function stripContainerPrefix(line) {
  let result = line;
  let previous;
  do {
    previous = result;
    result = result.replace(/^ {0,3}> ?/, '').replace(/^ {0,3}(?:[-+*]|\d+[.)])[ \t]+/, '');
  } while (result !== previous);
  return result;
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
  default:
    process.stderr.write(
      'usage: pr-body-contract.mjs (--author|--author-count|--has-self-review) < pr-body.md\n',
    );
    process.exitCode = 2;
}
