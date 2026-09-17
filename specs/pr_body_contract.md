# PR-body contract

`scripts/lib/pr-body-contract.mjs` is the single parser for the pull-request body declarations used by identity, review, and self-review checks. It accepts the existing CLI modes `--author`, `--author-count`, `--has-self-review`, and `--json`; `--json` continues to emit `author`, `authorCount`, and `hasSelfReview`.

## Marker and membership contract

`Authoring-Agent:` and `## Self-Review` retain their strict raw column-zero syntax. The parser counts every visible Authoring-Agent declaration, lowercases one valid identifier, and reports an empty author for zero, duplicate, or invalid declarations. A Self-Review marker is an exact level-two heading at source column one.

CommonMark with GFM extensions decides whether a raw candidate belongs to the document's top level. Candidates inside blockquotes, lists, fenced code, inline code, or raw HTML are excluded. Existing HTML-comment treatment remains: real HTML comments are removed before marker syntax is checked, while comment-looking text in code remains code. This contract does not add a Markdown dialect, a marker form, or a hand-maintained container parser.

The parser uses GFM tokenization and mdast handlers to establish source positions and block membership; it does not render Markdown or consume rewritten inline link nodes. Its GFM post-parse transforms are therefore omitted, retaining the CLI's marker and membership results while avoiding an irrelevant recursive linkification walk.

## Same-line list-nesting ceiling

Same-line list container nesting is capped at 64 levels. This is a resource-safety guard and carries no semantic claim.

micromark opens list containers with no nesting bound, and its document tokenizer re-shuffles its whole event array as each container opens, so a single line of repeated markers costs quadratic time: a 60,042-byte body of `'- '.repeat(30000)` does not complete in 45 seconds, while the parser this one replaces answers it in about 0.2 seconds. PR bodies are untrusted input that every validator invocation re-parses. micromark 4.0.2 and mdast-util-from-markdown 2.0.3 are the current upstream releases and neither exposes a depth option, so the ceiling lives in this adapter.

The ceiling is **not** derived from GitHub's rendering. cmark-gfm does cap list nesting, but it emits sibling items past its cap rather than folding deeper markers into the innermost item, so its lazy-continuation behaviour differs from what this gate produces; matching its number would not match its behaviour. Nothing here asserts that 64 levels is where list nesting stops being meaningful.

Truncating nesting can change the contract's answers, and at small ceilings it does. The value is therefore chosen empirically. Across 1,277,759 generated lines from eight seeds, whose nesting straddles each candidate, divergence from an unbounded parse falls away with depth: ceiling 20 diverges 7 times, ceiling 24 twice, ceiling 32 and ceiling 64 not at all. The margin above that tail is load-bearing rather than decorative---a corpus ten times smaller showed ceiling 24 clean, and only the larger one exposed it. Worst-case cost at GitHub's 65,536-character body limit is flat from 24 to 64 (about 3.2s CPU on Node 22 and 2.4s on Node 24, measured on the many-lines-at-the-ceiling shape that a ceiling steers an adversary toward), so going lower buys nothing and 64 takes the headroom. Every divergence observed at any ceiling was fail-closed, losing a declaration rather than inventing one.

Zero observed divergence is evidence about the tested corpus, not a proof of renderer fidelity or of general answer-preservation.

The ceiling is a gate, not a second parser. A construct registered before the upstream `list` construct at each marker code either lets it run untouched or, past the ceiling, disables it by name for exactly one attempt; a construct registered after it lifts that veto in the same attempt, so no later sibling item inherits it. No Markdown is tokenized by this repository.

## Generated runtime and rebuild

The generated standalone runtime remains at `scripts/lib/pr-body-contract.mjs`, the propagated consumer path. Its readable source and build inputs are hub-only: `scripts/lib/pr-body-contract.source.mjs` and `scripts/lib/pr-body-contract.bundle/`. A consumer executes only the generated runtime and performs no npm install or network operation.

Rebuild or verify it from a hub checkout with `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --write` or `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --check`. Both commands create a fresh temporary build directory, run the pinned `npm ci --ignore-scripts`, and bundle the source; `--check` byte-compares the result with the committed runtime and fails when it is stale.

The lock pins every build dependency. The rebuild uses its esbuild metafile to identify bundled packages and embeds each package's version, locked npm source, declared license, and packaged license text in the generated runtime. A generic attribution file is insufficient because consumers receive the standalone runtime.

## Regression coverage

`tests/test_pr_body_contract_parity.sh` verifies the stable CLI result and all existing consumers' shared-parser use. Its #1192 corpus covers renderer-confirmed quote-first-block, list-transition, nested-list, comment, code, and malformed-heading outcomes. Its #1281 controls pin the narrow guarantee the ceiling actually makes: the pathological body parses in bounded time, and a differential against an unbounded build of the same bundle observes no divergence. That differential asserts its own measured coverage first---how many generated lines crossed the ceiling, and whether every marker and content shape was drawn---because an earlier version used a generator whose float multiplication collapsed the depths to a set that never reached the ceiling, and so reported zero divergence against a ceiling it had not exercised.
