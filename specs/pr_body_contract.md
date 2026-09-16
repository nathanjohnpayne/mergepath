# PR-body contract

`scripts/lib/pr-body-contract.mjs` is the single parser for the pull-request body declarations used by identity, review, and self-review checks. It accepts the existing CLI modes `--author`, `--author-count`, `--has-self-review`, and `--json`; `--json` continues to emit `author`, `authorCount`, and `hasSelfReview`.

## Marker and membership contract

`Authoring-Agent:` and `## Self-Review` retain their strict raw column-zero syntax. The parser counts every visible Authoring-Agent declaration, lowercases one valid identifier, and reports an empty author for zero, duplicate, or invalid declarations. A Self-Review marker is an exact level-two heading at source column one.

CommonMark with GFM extensions decides whether a raw candidate belongs to the document's top level. Candidates inside blockquotes, lists, fenced code, inline code, or raw HTML are excluded. Existing HTML-comment treatment remains: real HTML comments are removed before marker syntax is checked, while comment-looking text in code remains code. This contract does not add a Markdown dialect, a marker form, or a hand-maintained container parser.

The parser uses GFM tokenization and mdast handlers to establish source positions and block membership; it does not render Markdown or consume rewritten inline link nodes. Its GFM post-parse transforms are therefore omitted, retaining the CLI's marker and membership results while avoiding an irrelevant recursive linkification walk.

## List-nesting bound

List container nesting is bounded at ten levels, the depth GitHub's own renderer stops at: `POST /markdown` returns exactly ten `<ul>` elements for `'- '.repeat(n)` at every `n >= 10`, folding deeper markers into the innermost item. micromark applies no such bound, and its document tokenizer re-shuffles the whole event array as each container opens, so a single line of repeated markers costs quadratic time---a 60,042-byte body of `'- '.repeat(30000)` does not complete in 45 seconds. PR bodies are untrusted input that every validator invocation re-parses.

The bound is a gate, not a second parser. A construct registered before the upstream `list` construct at each marker code either lets it run untouched or, past the bound, disables it by name for exactly one attempt; a construct registered after it lifts that veto in the same attempt, so no later sibling item inherits it. No Markdown is tokenized by this repository.

Truncating depth cannot change the contract's answers. Membership is the boolean "inside at least one container", and a candidate inside ten list levels is inside a container on either reading. A 60,000-body randomized differential across nesting depths that straddle the bound found no answer that differs from the unbounded parse.

## Generated runtime and rebuild

The generated standalone runtime remains at `scripts/lib/pr-body-contract.mjs`, the propagated consumer path. Its readable source and build inputs are hub-only: `scripts/lib/pr-body-contract.source.mjs` and `scripts/lib/pr-body-contract.bundle/`. A consumer executes only the generated runtime and performs no npm install or network operation.

Rebuild or verify it from a hub checkout with `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --write` or `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --check`. Both commands create a fresh temporary build directory, run the pinned `npm ci --ignore-scripts`, and bundle the source; `--check` byte-compares the result with the committed runtime and fails when it is stale.

The lock pins every build dependency. The rebuild uses its esbuild metafile to identify bundled packages and embeds each package's version, locked npm source, declared license, and packaged license text in the generated runtime. A generic attribution file is insufficient because consumers receive the standalone runtime.

## Regression coverage

`tests/test_pr_body_contract_parity.sh` verifies the stable CLI result and all existing consumers' shared-parser use. Its #1192 corpus covers renderer-confirmed quote-first-block, list-transition, nested-list, comment, code, and malformed-heading outcomes. Its #1281 controls pin both halves of the list-nesting bound: an over-deep body parses in bounded time and still yields the top-level contract, while declarations genuinely inside the over-deep list, its lazy continuation, and its sibling items stay excluded exactly as the renderer places them.
