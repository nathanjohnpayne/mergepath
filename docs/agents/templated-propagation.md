# Templated propagation — Layer 5 substitution lib

Status: **lib + sync/audit integration + propagation-lane verification landed.** Templated propagation PRs are now lane-eligible alongside canonical/kit — the verifier re-renders against `mergepath@<sha>` with the consumer's facts and byte-compares against the PR's dest.

This doc covers `scripts/lib/template-substitution.sh` — the rendering engine that activates `type: templated` entries in `.mergepath-sync.yml` — plus the sync integration that wires it into `scripts/sync-to-downstream.sh` for both audit and materialize.

## What the lib does

Renders a source template to per-consumer output using two surfaces:

1. **Variable substitution** — anywhere in the file, `{{key}}` is replaced by the value of `MERGEPATH_FACT_KEY` (uppercased, hyphens → underscores). Keys must match `[a-z0-9_-]+` (lowercase letters, digits, underscore, hyphen); a malformed key — e.g. one containing shell metacharacters — is rejected as malformed template (render exit code 1), distinct from a syntactically valid but unset fact (which is empty in lenient mode or exit code 3 in strict mode).
2. **Conditional blocks** — `>>> if <expr> ... <<<` markers gate body lines on per-consumer facts. Marker lines are **always stripped** from output regardless of the expression; only the body lines between them are conditional. If `<expr>` is true, body lines are emitted verbatim; if false, body lines are dropped.

Sync-side integration (landed; see § Sync integration below) is responsible for exporting per-consumer facts from the manifest before invoking the lib. The lib itself reads facts only from the environment.

## Syntax reference

### Variables

```text
hello {{name}}!
ts version {{node_version}}
```

- Missing facts render as empty string in lenient mode (default).
- Set `MERGEPATH_TEMPLATE_STRICT=1` to make a reference-to-unset-fact a hard error (exit code 3).
- Unclosed `{{` (no matching `}}`) is emitted verbatim — no error. The lib is permissive here so accidental token-like sequences in real source files don't false-fail.

### Conditional blocks

```js
// >>> if frameworks contains react
import react from "eslint-plugin-react";
// <<<
```

The leading comment prefix on a marker line is **stripped on parse** — the lib accepts any run of non-alphanumeric characters before the `>>>`/`<<<` sigil, so all of these work:

- `// >>> if ...` / `// <<<` — JS, TS, C, C++, Rust, Go
- `# >>> if ...` / `# <<<` — bash, YAML, Python, TOML
- `-- >>> if ...` / `-- <<<` — SQL, Lua, Haskell
- `<!-- >>> if ... -->` / `<!-- <<< -->` — HTML, XML
- Leading whitespace before the comment chars is allowed.

A kept block's body lines survive verbatim (including their own leading whitespace, comments, etc.). A skipped block drops every line between the markers — the markers themselves never appear in output.

### Expression forms (v1)

Inside `>>> if <expr>`, the lib supports:

| Form | True when |
|---|---|
| `<key>` | `MERGEPATH_FACT_KEY` is set and non-empty |
| `!<key>` | `MERGEPATH_FACT_KEY` is unset or empty |
| `<key> contains <value>` | `<value>` appears as a space-separated word in `MERGEPATH_FACT_KEY` |
| `<key> == <value>` | string equality |
| `<key> != <value>` | string inequality |

`contains` matches at word boundaries — `frameworks contains react` is false when `MERGEPATH_FACT_FRAMEWORKS="react-native"`, true when it's `"react typescript"`. Use distinct values for distinct concepts; don't rely on substring matching.

Anything else in the expression slot (including a `<key>` that fails the `[a-z0-9_-]+` charset check) is a malformed-template error (exit code 1) with a diagnostic listing the supported forms.

### v1 deliberately omits

- **Nested conditionals.** A second `>>> if` while another is still open is an error. The first real templated source (`examples/eslint.config.js` after Phase C) doesn't need nesting; relax later if a real source does.
- **`else` / `elif`.** Express the alternative as a second top-level block with the negated condition.
- **Loops or iteration.** Out of scope. Per-consumer expansion happens at the sync-call layer, not inside templates.
- **Block-comment-only languages (JSON, CSS-without-`//`).** Templates must be in a language that supports the `<comment-chars> >>> ... <comment-chars> <<<` shape on its own line. Most config-as-code files satisfy this; JSON does not (workaround: use JSON5 or move the templated piece into a `.js` wrapper).

## API

Source the lib, then call:

```bash
source "scripts/lib/template-substitution.sh"

# Render to stdout. Exit 0 success, 1 malformed template, 2 source-file
# missing, 3 unknown fact in strict mode.
template_substitution::render path/to/template.tpl

# Atomic write via mktemp + mv. Same exit codes as render.
template_substitution::render_to path/to/template.tpl path/to/dest

# Expression evaluator exposed for direct testing.
template_substitution::eval_expr "frameworks contains react"
# Returns 0 (true), 1 (false), or 2 (malformed expression).
```

The lib enables `set -euo pipefail` **only** when the file is executed directly (the noop usage-hint path at the bottom). When sourced — the normal case — no global shell options are toggled, so `render` and `render_to` will not clobber the caller's `set -e` / `set -u` / `pipefail` state. Callers capture exit codes with the standard `|| rc=$?` pattern.

## Why this syntax — design rationale

This section records the decisions taken so a future reader (or a reviewer asking "why didn't you just use Mustache?") doesn't have to reconstruct the trade-offs.

### Why comment-prefix-agnostic markers, not `{{#if}}…{{/if}}`

Mustache-style conditional markers (`{{#if frameworks.react}}…{{/if}}`) would have been the obvious choice — they're familiar and unambiguous. We picked comment-prefix markers instead because:

1. **A source template that's valid in its target language stays editor-friendly.** `examples/eslint.config.js` with comment markers parses, lints, and previews exactly like a real ESLint config. Mustache `{{#if}}` would break syntax highlighting and prevent in-place evaluation. Templates that look like real code are easier to maintain.
2. **No new dependency.** Pure bash, no vendored renderer, no shell-out to node. Matches the rest of `scripts/lib/`.
3. **Mergepath already considered and rejected `{{TOKEN}}` markers for bootstrap-time name substitution** (`scripts/bootstrap/substitute.sh:19-27`). The rationale there was "markers visible to direct readers — bad UX." The constraint is weaker for templated propagation (template files clearly live under `examples/`, readers expect templating), but the precedent informed the syntax choice — line-comment markers are even more invisible to direct readers than Mustache tokens.

`{{var}}` substitution is retained for the variable-replacement surface because it's the same shape `scripts/bootstrap/substitute.sh` already uses for `MERGEPATH_DESCRIPTION_HERE`-style markers, and conflating two syntaxes for "replace this with a value" is unnecessary churn.

### Why facts in env vars, not a manifest sub-block

The lib is invoked once per `<consumer × templated path>` combination by the sync script. The sync script reads `.mergepath-sync.yml`, extracts the consumer's facts, exports them as `MERGEPATH_FACT_<KEY>=<value>`, then forks the renderer. Passing facts via env is the most-portable way to hand structured data to a bash subprocess without a tempfile or stdin dance. It also keeps the lib trivially testable — tests just export the env and source the lib directly, with no manifest fixture needed.

### Why no nested conditionals in v1

The forcing function (`eslint.config.js` per consumer) has at most one layer of conditionals — independent framework blocks. Allowing nesting from day one would have added a stack-management state machine to the renderer for zero current benefit. The v1 lib explicitly fails on a second open marker so a future need surfaces loud rather than silently producing wrong output.

### Why strict-mode is opt-in, not the default

Real templates will accumulate optional-fact references over time (`{{node_version}}`, `{{lint_glob}}`, etc.) and not every consumer will set every fact. Lenient default avoids forcing every fact to be declared on every consumer just to satisfy the renderer. Strict mode is available for CI checks that want hard-fail behavior (e.g., "every consumer with `frameworks contains typescript` must declare `node_version`").

## Limits and known gaps

- **No live templated entry in the manifest yet.** The lib + sync integration are wired (audit, materialize for per-commit + sync-all), but `.mergepath-sync.yml` has zero entries of `type: templated` today. Phase C adds the first one (`examples/eslint.config.js` → `eslint.config.js`) to unblock the [mergepath#250](https://github.com/nathanjohnpayne/mergepath/issues/250) ESLint rollout.
- **The lib doesn't know about consumer name or repo.** Facts must be uniform across consumers (e.g., `frameworks`, `node_version`); per-consumer name substitution (`mergepath` → `<consumer>`) still goes through `scripts/bootstrap/substitute.sh`'s allow-list-driven path. Long-term, both should share a single substitution lib (per [#168 Layer 5's original sketch](https://github.com/nathanjohnpayne/mergepath/issues/168) — "factor the substitution logic into `scripts/lib/template-substitution.sh` so bootstrap and sync share the lib"), but that consolidation is non-trivial because the two callers have different semantics (literal name allow-list vs. fact-driven substitution). Tracked as future work.
- **Per-consumer name substitution still goes through `scripts/bootstrap/substitute.sh`.** The templating lib is fact-driven (`MERGEPATH_FACT_*`); consumer-name substitution at bootstrap time still goes through the allow-list-driven bootstrap path. Long-term consolidation tracked in [#168 Layer 5](https://github.com/nathanjohnpayne/mergepath/issues/168).

## Sync integration — what's wired up

The follow-up integration PR landed:

1. **Manifest schema** — `.mergepath-sync.yml` supports `facts:` blocks on consumers (mapping of `[a-z0-9_-]+` keys to scalar/list values) and `source:` + `dest:` fields on path entries (both default to `.path` when omitted; templated entries typically declare both because source ≠ dest is the point).

2. **`scripts/ci/check_sync_manifest`** — validates the new schema. Templated entries without an explicit `dest:` produce a WARN (the source-dest decoupling is the whole point). Facts values that are nested mappings are rejected (the lib expects scalar/list); facts keys outside `[a-z0-9_-]+` are rejected (lib contract).

3. **`scripts/sync-to-downstream.sh --audit`** — `compare_templated()` renders the source with the consumer's facts and byte-diffs against the consumer's on-disk dest. Reports `ok` / `drift:<lines>` / `missing` in the same tag scheme as canonical/kit.

4. **`scripts/sync-to-downstream.sh <commit-sha>`** (per-commit slice) — `materialize_templated_targets()` renders each opted-in templated entry that changed at the commit and writes to the consumer's dest. Honors `.sync-overrides.yml` on the dest path. The commit body lists the templated paths with a "(templated, rendered from <source>)" annotation.

5. **`scripts/sync-to-downstream.sh --sync-all`** (steady-state) — same materialize behavior for every templated entry the consumer opts into, regardless of changed-at-commit. Dry-run plan output shows templated targets explicitly.

### Manifest example

```yaml
consumers:
  - name: matchline
    repo: nathanjohnpayne/matchline
    visibility: public
    facts:
      frameworks: [react, typescript]
      node_version: "20"

paths:
  - path: examples/eslint.config.js
    type: templated
    source: examples/eslint.config.js
    dest: eslint.config.js
    consumers: [matchline, swipewatch, ...]
```

A render for matchline exports `MERGEPATH_FACT_FRAMEWORKS="react typescript"` and `MERGEPATH_FACT_NODE_VERSION=20`, then runs the lib against `examples/eslint.config.js`. The output lands at `eslint.config.js` in the consumer's PR branch.

## Propagation-lane verification

The `propagation_prs` review-lane exemption in `.github/review-policy.yml` (#264) covers templated entries via a re-render + byte-verify path that lives alongside the canonical/kit byte-compare ([#323](https://github.com/nathanjohnpayne/mergepath/issues/323)).

How it works:

1. `scripts/workflow/verify-propagation-pr.sh` parses templated entries from the trusted mergepath checkout's manifest.
2. For each templated entry whose `dest` appears in the PR's diff AND whose consumer matches this PR's repo, the verifier:
   - resolves the consumer via `$MERGEPATH_CONSUMER` (test/CI escape hatch) OR the consumer dir's `origin` remote URL matched against `.consumers[].repo`,
   - sources `scripts/lib/manifest-fact-helpers.sh` from the trusted mergepath checkout and calls `export_consumer_facts <consumer> <manifest>` to populate `MERGEPATH_FACT_*`,
   - sources `scripts/lib/template-substitution.sh` from the trusted mergepath checkout and calls `template_substitution::render <source>` to produce the expected output,
   - `git show ${HEAD_SHA}:${dest}` to pull the PR's dest content, and byte-compares with `diff -q`.
3. On match, the verified `dest` is added to a `VERIFIED_TEMPLATED_DESTS` list so the canonical-loop path-confinement check below it skips that file (templated `dest` doesn't equal any `.path`, so without this exemption the canonical check would false-fail it).
4. On match, a structured stdout line is emitted for the calling workflow to post as a thread tag-reply:

   ```text
   [mergepath-verify: templated-render] <dest> <consumer> <source>
   ```

5. Failures fall into typed buckets in the verifier's stderr summary:
   - **Canonical / kit drift** — pre-existing canonical surface.
   - **Templated re-render mismatch** — rendered output differs from PR dest content.
   - **Templated mode/type drift** — the rendered dest's git tree entry (mode + type) does not match the SOURCE template's. The render preserves the source template's git mode, so an **executable** templated source (e.g. a templated shell script) must render to an **executable** dest; a `chmod +x` flip or symlink swap relative to the source is rejected (#471). The verifier reads the source mode from the trusted mergepath checkout — it is NOT a hardcoded `100644`.
   - **Templated re-render error** — malformed template, missing source at mergepath@<sha>, or strict-mode unset fact.

Consumer-inference fallback: if neither `$MERGEPATH_CONSUMER` is set nor the `origin` remote matches a `.consumers[].repo` field, the templated arm is skipped with a stderr note. The canonical/kit arm still runs, and the templated dest will then fail the path-confinement check, routing the PR to normal Phase 4 review (pre-#323 status quo).

Wire-up:

- CI gate: `scripts/ci/check_workflow_verify_propagation_templated` (test: `tests/test_verify_propagation_pr_templated.sh`) covers pass, content drift, template syntax error, strict-mode unset fact, mode tampering, and executable-source mode preservation (#471). Wired into `.github/workflows/repo_lint.yml` alongside `check_verify_propagation_pr`.
- Rollup attribution: the `templated-render` tag class lives in `scripts/lib/daily-feedback-rollup-helpers.sh` (mapped to `skip` in `tag_class_action`, same routing as `canonical-coverage`) and `scripts/resolve-pr-threads.sh`'s `derive_tag_class` ladder (slotted at rung 1b, right after `canonical-coverage`). Findings on a templated dest are structurally a mergepath concern — fixes belong in the template or in the consumer's `facts:` block — so they route to mergepath rather than surfacing per-consumer.
- Consumer-safe CI gate (#467): `check_workflow_verify_propagation_templated` propagates to consumers via the `scripts/ci/` kit, but its wrapped test (`tests/test_verify_propagation_pr_templated.sh`) is NOT in the manifest's consumer set, so it is legitimately absent in a consumer checkout. It uses `.mergepath-sync.yml` as the canonical/consumer discriminator (same shape as `check_bootstrap_sh`): manifest **present** (canonical) → a missing test is a hard error so an accidental delete/rename surfaces in CI; manifest **absent** (consumer) → SKIP rather than red the consumer's repo-lint for a file it never receives. By contrast, `check_verify_propagation_pr` hard-errors on a missing test in **both** modes and does NOT carry this skip: its wrapped tests are `consumers: all` AND listed in the kit `requires:`, so they travel to every consumer — a missing one means propagation broke and must surface, never be skipped (a manifest-gated skip there is a fail-open; Codex P2 on PR #477).
- Scalar `consumers: all` resolution (#467): `resolve-pr-threads.sh`'s templated-dest cache resolves consumer scope for the `templated-render` class. The `consumers` field is either a sequence of names or the scalar literal `all`; the scalar form is resolved in a separate yq pass (mikefarah yq cannot `map` over a string, and a single un-guarded scalar entry would otherwise blank the entire cache and silently disable templated-render classification).

## What's queued next

1. **Phase C** — restructure `examples/eslint.config.js` into a conditional-block template, add `facts.frameworks` to all 8 consumer entries, add the manifest entry for `eslint.config.js`.
2. **Phase D** — canary propagation to swipewatch (smallest JS surface), then fanout to the remaining 5 consumers. Each consumer's PR carries the rendered config + a devDeps install + findings triage per its consumer-side issue.
3. **Phase E** — close the 6 consumer issues and the [mergepath#250](https://github.com/nathanjohnpayne/mergepath/issues/250) parent tracker; file a retrospective on Layer 5 cost vs. payoff for future "should we templated-ize X?" judgment calls.
4. ~~**Lane-eligibility for templated** — extend `verify-propagation-pr.sh` to re-render-and-verify templated entries.~~ **Landed in [#323](https://github.com/nathanjohnpayne/mergepath/issues/323)** — see § Propagation-lane verification above.
