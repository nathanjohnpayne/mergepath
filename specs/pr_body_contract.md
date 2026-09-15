# PR-body contract

`scripts/lib/pr-body-contract.mjs` is the single parser for the pull-request body declarations used by identity, review, and self-review checks. It accepts the existing CLI modes `--author`, `--author-count`, `--has-self-review`, and `--json`; `--json` continues to emit `author`, `authorCount`, and `hasSelfReview`.

## Marker and membership contract

`Authoring-Agent:` and `## Self-Review` retain their strict raw column-zero syntax. The parser counts every visible Authoring-Agent declaration, lowercases one valid identifier, and reports an empty author for zero, duplicate, or invalid declarations. A Self-Review marker is an exact level-two heading at source column one.

CommonMark with GFM extensions decides whether a raw candidate belongs to the document's top level. Candidates inside blockquotes, lists, fenced code, inline code, or raw HTML are excluded. Existing HTML-comment treatment remains: real HTML comments are removed before marker syntax is checked, while comment-looking text in code remains code. This contract does not add a Markdown dialect, a marker form, or a hand-maintained container parser.

## Generated runtime and rebuild

The generated standalone runtime remains at `scripts/lib/pr-body-contract.mjs`, the propagated consumer path. Its readable source and build inputs are hub-only: `scripts/lib/pr-body-contract.source.mjs` and `scripts/lib/pr-body-contract.bundle/`. A consumer executes only the generated runtime and performs no npm install or network operation.

Rebuild or verify it from a hub checkout with `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --write` or `node scripts/lib/pr-body-contract.bundle/rebuild.mjs --check`. Both commands create a fresh temporary build directory, run the pinned `npm ci --ignore-scripts`, and bundle the source; `--check` byte-compares the result with the committed runtime and fails when it is stale.

The lock pins every build dependency. The rebuild uses its esbuild metafile to identify bundled packages and embeds each package's version, locked npm source, declared license, and packaged license text in the generated runtime. A generic attribution file is insufficient because consumers receive the standalone runtime.

## Regression coverage

`tests/test_pr_body_contract_parity.sh` verifies the stable CLI result and all existing consumers' shared-parser use. Its #1192 corpus covers renderer-confirmed quote-first-block, list-transition, nested-list, comment, code, and malformed-heading outcomes.
