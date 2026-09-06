#!/usr/bin/env node

import { readFileSync } from 'node:fs';

// HTML block starters shared between the top-level block dispatch below and
// interruptsParagraph()'s CommonMark paragraph-interruption check, so the
// two classifications cannot drift apart.
// GFM/CommonMark's inter-token whitespace is space/tab only, not the full
// Unicode set JavaScript's \s matches (e.g. U+2003). Using \s here let a
// Unicode-whitespace-separated tag like "<pre\u2003>" open a raw HTML block
// that cmark-gfm would not, ending a code-span search early.
const RAW_TAG_RE = /^ {0,3}<(script|pre|style|textarea)(?:[ \t]|>|$)/i;
const PROCESSING_INSTRUCTION_RE = /^ {0,3}<\?/;
const CDATA_RE = /^ {0,3}<!\[CDATA\[/;
const DECLARATION_RE = /^ {0,3}<![A-Z]/;
// CommonMark HTML block condition 6's fixed tag-name list. Condition 7's
// complete-generic-tag rule is deliberately NOT included here: unlike
// conditions 1-6, condition 7 cannot interrupt a paragraph.
const FIXED_TAG_LIST_RE =
  /^ {0,3}<\/?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[ \t]|\/?>|$)/i;
const HTML_COMMENT_OPEN_RE = /^ {0,3}<!--/;

const BLOCKQUOTE_RE = /^ {0,3}>/;
const BARE_LIST_MARKER_RE = /^ {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]|$)/;

// A line made of only "=" is always a setext underline; a line made of only
// "-" is ambiguous between a setext underline and a thematic break, and one
// made of only "_" or "*" (3+, CommonMark requires at least 3 for these two)
// is always a thematic break. CommonMark resolves the "-" ambiguity in favor
// of ending the paragraph either way, so BOTH classifications matter here
// for a DIFFERENT reason than in most parsers: this predicate does not need
// to pick one, but a pure-dash line must NOT also be read as a list marker,
// or a thematic break like "- - -" would be mistaken for an ongoing list
// container that swallows real content after it.
const SETEXT_OR_THEMATIC_DASH_RE = /^ {0,3}(?:-[ \t]*)+$/;
const SETEXT_EQUALS_RE = /^ {0,3}=+[ \t]*$/;
const THEMATIC_UNDERSCORE_RE = /^ {0,3}(?:_[ \t]*){3,}$/;
const THEMATIC_ASTERISK_RE = /^ {0,3}(?:\*[ \t]*){3,}$/;

function isSetextOrThematicLine(line) {
  return (
    SETEXT_EQUALS_RE.test(line) ||
    SETEXT_OR_THEMATIC_DASH_RE.test(line) ||
    THEMATIC_UNDERSCORE_RE.test(line) ||
    THEMATIC_ASTERISK_RE.test(line)
  );
}

// Container markers shared between interruptsParagraph() (does a fresh
// top-level paragraph get interrupted here?) and the main loop's lazy-
// continuation tracking (once already inside a blockquote/list item, does
// THIS line still belong to it?). Deliberately more permissive than
// isInterruptingListItem() below: an empty/bare marker cannot freshly
// INTERRUPT a paragraph, but it is still container content once already
// inside one -- excluding thematic-break-shaped lines either way, per the
// comment above.
function isContainerMarker(line) {
  return BLOCKQUOTE_RE.test(line) || (BARE_LIST_MARKER_RE.test(line) && !isSetextOrThematicLine(line));
}

// Lazy continuation extends an OPEN PARAGRAPH inside the container -- never
// any other block type. A container line whose own content (after its
// marker) is itself blank, or is itself a heading/fence/another
// container/etc., has NO open paragraph, so nothing that follows it is a
// lazy continuation: "> # quoted heading" opens a heading inside the quote,
// not a paragraph, so an unprefixed "Authoring-Agent:" line right after it
// is a fresh top-level paragraph, not nested content. Assumes line already
// satisfies isContainerMarker(line).
function opensLazyParagraph(line) {
  const blockquote = line.match(BLOCKQUOTE_RE);
  if (blockquote) {
    const remainder = line.slice(blockquote[0].length).replace(/^ /, '');
    return remainder.trim() !== '' && !interruptsParagraph(remainder);
  }
  const listItem = line.match(/^ {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]+(\S.*)?)?$/);
  const remainder = (listItem?.[1] ?? '').trim();
  return remainder !== '' && !interruptsParagraph(remainder);
}

// A GENUINE list item: unlike isContainerMarker() above, requires real
// content after the marker (CommonMark: an empty list item cannot interrupt
// a paragraph) and, for an ordered marker, a NUMERIC start value of 1
// (leading zeros count, e.g. "01." -- CommonMark: an ordered list
// interrupts a paragraph only when it starts at 1).
function isInterruptingListItem(line) {
  if (isSetextOrThematicLine(line)) return false;
  const match = line.match(/^ {0,3}(?:([-+*])|(\d{1,9})[.)])[ \t]+\S/);
  if (!match) return false;
  return match[1] != null || Number(match[2]) === 1;
}

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
  // Once inside a blockquote or list item, a following line with no marker
  // of its own is a LAZY CONTINUATION of it in CommonMark -- still nested,
  // not a new top-level paragraph -- until a blank line or another
  // interrupting construct ends it. Without tracking this, a line like
  // "Authoring-Agent: attacker" right after "> quoted" (no blank line) was
  // read as a live top-level declaration when CommonMark renders it inside
  // the quote, letting nested content satisfy the identity contract.
  let lazyContainer = false;

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

    // Checked before the indentedCode short-circuit below (and before
    // fence/comment/code-span opening): a whitespace-only line is blank
    // regardless of how much whitespace it carries -- 4+ spaces or a tab
    // included -- and interruptsParagraph's blank check already handles any
    // length. Checking indentedCode first would swallow such a line as
    // "indented code" and leave lazyContainer stuck set, suppressing a
    // valid top-level declaration after it. A construct that opens one of
    // the other states (e.g. a bare fence with no ">" prefix) genuinely
    // exits the container, and this line's OWN handling of that state
    // takes over from here as normal.
    if (lazyContainer) {
      if (isContainerMarker(rawLine)) {
        // Re-evaluate on every explicit continuation line: a later "> ..."
        // can open (or fail to open) its own paragraph independently of
        // whatever came before it in the same container.
        lazyContainer = opensLazyParagraph(rawLine);
        continue;
      }
      if (interruptsParagraph(rawLine)) {
        lazyContainer = false;
      } else {
        continue;
      }
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

    const rawTag = line.match(RAW_TAG_RE);
    if (rawTag) {
      if (!new RegExp(`</${rawTag[1]}\\s*>`, 'i').test(line)) {
        htmlBlock = rawTag[1].toLowerCase();
      }
      continue;
    }
    if (PROCESSING_INSTRUCTION_RE.test(line)) {
      if (!line.includes('?>')) htmlBlock = 'processing';
      continue;
    }
    if (CDATA_RE.test(line)) {
      if (!line.includes(']]>')) htmlBlock = 'cdata';
      continue;
    }
    if (DECLARATION_RE.test(line)) {
      if (!line.includes('>')) htmlBlock = 'declaration';
      continue;
    }
    // CommonMark HTML block condition 6 uses a fixed tag-name list and does
    // not require a closing `>`: `<div` at end of line starts a raw block that
    // runs until the next blank line. Keep this distinct from condition 7's
    // complete generic-tag rule so `<foo` remains ordinary prose.
    if (FIXED_TAG_LIST_RE.test(line)) {
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

    // A fresh blockquote or list item at top level: IF it opens a
    // paragraph (see opensLazyParagraph), everything that follows it, up to
    // a blank line or another interrupting construct, is that paragraph's
    // lazy continuation (see the lazyContainer declaration above). A
    // container whose own content is a heading/fence/etc. has no open
    // paragraph, so lazyContainer stays false and the next line is fresh.
    if (isContainerMarker(line)) {
      lazyContainer = opensLazyParagraph(line);
      continue;
    }

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
  const discardLine = initialState || HTML_COMMENT_OPEN_RE.test(line);

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
  // A code span's closer must land in the SAME paragraph as its opener: in
  // CommonMark, inline parsing (and so backtick pairing) never crosses a
  // paragraph boundary. Without this bound, a stray/unmatched backtick
  // anywhere earlier in the body could pair with an unrelated backtick many
  // paragraphs later -- e.g. a typo'd "call`s own" pairing with the next
  // real `code span` and swallowing every top-level marker in between,
  // including a genuine "## Self-Review" heading (reproduced on #1122).
  for (let index = lineIndex; index < lines.length; index += 1) {
    if (index > lineIndex && interruptsParagraph(lines[index])) return false;
    const candidate = index === lineIndex ? lines[index].slice(column) : lines[index];
    for (const match of candidate.matchAll(/`+/g)) {
      if (match[0].length === runLength) return true;
    }
  }
  return false;
}

// Every CommonMark construct that ends the paragraph an opening backtick
// belongs to -- so hasMatchingCodeSpanRun's search never reaches past it
// looking for a closer. Each interrupts UNCONDITIONALLY, with no blank line
// required first (blank lines are the trivial case, handled by the first
// branch below). Missing any one of these lets a stray backtick before it
// pair with an unrelated backtick beyond it, the same #1122 swallowing bug
// in a different shape -- this file's own tests (LIST_CONTINUATION,
// BLOCKQUOTE_MARKERS, REAL_FENCE, REAL_HTML, etc.) already establish that
// content nested inside any of these constructs is never a top-level
// marker, so a code span reaching past one risks swallowing a genuine
// marker that follows it, exactly as an unswallowed heading would.
function interruptsParagraph(line) {
  // Blank line (CommonMark: spaces/tabs only, or nothing -- NOT JavaScript's
  // broader trim() whitespace set, which also strips Unicode separators like
  // U+2003. A line of pure U+2003 is not blank in CommonMark, so treating it
  // as one would end a code-span search early and let genuine code-span
  // content, e.g. a smuggled "Authoring-Agent:" line, surface as a live
  // top-level declaration instead of staying hidden inline code.)
  if (/^[ \t]*$/.test(line)) return true;
  // ATX heading, e.g. "## Self-Review" itself.
  if (/^ {0,3}#{1,6}(?:[ \t]|$)/.test(line)) return true;
  // Fenced code block opener. A backtick fence's info string cannot itself
  // contain a backtick (mirrors the top-level fence-open check above); a
  // tilde fence has no such restriction. Without this, a line like
  // "```foo`bar" -- not a valid fence opener -- would wrongly end the
  // search early, exactly the class of bug this boundary exists to avoid.
  if (/^ {0,3}`{3,}[^`]*$/.test(line)) return true;
  if (/^ {0,3}~{3,}/.test(line)) return true;
  // Blockquote.
  if (BLOCKQUOTE_RE.test(line)) return true;
  // List item: requires real content after the marker (CommonMark: an empty
  // item cannot interrupt) and, for an ordered marker, a numeric start value
  // of 1 -- "2. item" does not interrupt, so a real code span may
  // legitimately cross such a line.
  if (isInterruptingListItem(line)) return true;
  // Setext heading underline (contiguous "=" or "-", nothing else) and
  // thematic break (3+ of the same "-", "_", or "*", each optionally
  // followed by spaces/tabs). A line of dashes can satisfy both; either
  // interpretation ends the paragraph above it, so this does not need to
  // disambiguate which one CommonMark would actually render.
  if (isSetextOrThematicLine(line)) return true;
  // HTML blocks (conditions 1-6, shared with the top-level dispatch above;
  // condition 7's generic complete tag is deliberately excluded -- unlike
  // 1-6, it cannot interrupt a paragraph in CommonMark).
  if (RAW_TAG_RE.test(line)) return true;
  if (HTML_COMMENT_OPEN_RE.test(line)) return true;
  if (PROCESSING_INSTRUCTION_RE.test(line)) return true;
  if (CDATA_RE.test(line)) return true;
  if (DECLARATION_RE.test(line)) return true;
  if (FIXED_TAG_LIST_RE.test(line)) return true;
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
