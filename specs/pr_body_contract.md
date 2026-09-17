# PR-body contract

`scripts/lib/pr-body-contract.mjs` is the single parser for the pull-request body declarations used by identity, review, and self-review checks. It accepts the existing CLI modes `--author`, `--author-count`, `--has-self-review`, and `--json`; `--json` continues to emit `author`, `authorCount`, and `hasSelfReview`.

## Marker and membership contract

`Authoring-Agent:` and `## Self-Review` retain their strict raw column-zero syntax. The parser counts every visible Authoring-Agent declaration, lowercases one valid identifier, and reports an empty author for zero, duplicate, or invalid declarations. A Self-Review marker is an exact level-two heading at source column one.

CommonMark with GFM extensions decides whether a raw candidate belongs to the document's top level. Candidates inside blockquotes, lists, footnote definitions, fenced code, inline code, or raw HTML are excluded. A footnote definition is a container in the same sense a list item is: an unindented, non-interrupting line after `[^x]: note` is a lazy continuation of the definition's paragraph, and GitHub renders it inside the footnote, or not at all when nothing references that footnote. Treating such a line as a live declaration would spoof author identity, so the node type is part of the container set. A blank line closes the definition and an ATX heading interrupts it, and both leave what follows genuinely top-level. Existing HTML-comment treatment remains: real HTML comments are removed before marker syntax is checked, while comment-looking text in code remains code. This contract does not add a Markdown dialect, a marker form, or a hand-maintained container parser.

The parser uses GFM tokenization and mdast handlers to establish source positions and block membership; it does not render Markdown or consume rewritten inline link nodes. Its GFM post-parse transforms are therefore omitted, retaining the CLI's marker and membership results while avoiding an irrelevant recursive linkification walk.

## Known limitation: deep same-line list nesting

micromark opens list containers with no nesting bound, and its document tokenizer re-shuffles its whole event array as each container opens, so a single line of repeated list markers costs quadratic time. A 60,042-byte body of `'- '.repeat(30000)` does not complete in 45 seconds, where the handwritten parser this one replaces answers it in about 0.2 seconds. PR bodies are untrusted input that every validator invocation re-parses, so this is a denial-of-service surface. micromark 4.0.2 and mdast-util-from-markdown 2.0.3 are the current upstream releases and neither exposes a depth option.

A per-line nesting ceiling was implemented and withdrawn. It bounds the cost, but **that veto strategy** cannot be made answer-preserving: vetoing a marker turns it into paragraph content, which changes whether the next unindented line is a lazy continuation. This is a result about the two strategies measured below, not a proof that no bounded implementation can preserve answers---a mitigation that *rejects* an over-nested body outright, rather than parsing it under a veto, is a different design and is not ruled out by this evidence. In a targeted search over bodies whose nesting sits within ten levels of the ceiling, roughly 66% diverged from an unbounded parse at ceilings of 64, 128 and 256 alike---the rate is a property of the boundary, not of its height, so raising the ceiling only moves which bodies are misclassified. Every divergence was fail-closed, rejecting a valid declaration. That search was a one-off experiment run while the ceiling existed; it is not part of the committed suite, which carries no depth corpus, so the figure belongs to the experiment that produced it and is recorded here rather than asserted by a test. A cost-proportional variant bounding total containers rather than per-line depth was also measured and is worse on cost (15s at a 1,000-container budget, 140s at 8,000), because vetoing new opens does not unwind the containers already open.

Blockquote nesting is not affected: it costs 96ms at 5,000 levels, 191ms at 15,000, 1,042ms at 30,000 and 1,256ms at 32,760, the deepest a 65,536-character body can express. Superlinear, but already bounded near 1.3s by the body-size limit.

This limitation is tracked separately and is not repaired by this change.

## Generated runtime and rebuild

The generated standalone runtime remains at `scripts/lib/pr-body-contract.mjs`, the propagated consumer path. Its readable source and build inputs are hub-only: `scripts/lib/pr-body-contract.source.mjs` and `scripts/lib/pr-body-contract.bundle/`. A consumer executes only the generated runtime and performs no npm install or network operation.

Rebuild or verify it from a hub checkout with `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --write` or `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --check`. Both commands create a fresh temporary build directory, run the pinned `npm ci --ignore-scripts`, and bundle the source; `--check` byte-compares the result with the committed runtime and fails when it is stale.

The lock pins every build dependency. The rebuild uses its esbuild metafile to identify bundled packages and embeds each package's version, locked npm source, declared license, and packaged license text in the generated runtime. A generic attribution file is insufficient because consumers receive the standalone runtime.

## Regression coverage

`tests/test_pr_body_contract_parity.sh` verifies the stable CLI result and all existing consumers' shared-parser use. Its #1192 corpus covers renderer-confirmed quote-first-block, list-transition, nested-list, comment, code, and malformed-heading outcomes.
